// Unit tests for provider readiness and the Razorpay reconciliation comparison.
// Run: node --test supabase/tests/edge/*.test.mjs   (Node >= 22.18 strips the TypeScript types)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { providerReadiness, blockedBody } from '../../functions/_shared/provider.ts';
import { comparePayments, compareRefunds } from '../../functions/_shared/reconcile.ts';

const none = { provider: 'razorpay_route', routeEnabled: false, hasKeyId: false, hasKeySecret: false, hasRazorpayxAccount: false, operatorsOnboarded: false };

test('manual SBI settlement needs no provider setup', () => {
  assert.deepEqual(providerReadiness({ ...none, provider: 'manual_sbi' }), { ready: true, blockers: [] });
});

test('Razorpay Route is blocked, and says exactly why', () => {
  const r = providerReadiness(none);
  assert.equal(r.ready, false);
  assert.ok(r.blockers.some((b) => b.includes('Route approval')));
  assert.ok(r.blockers.some((b) => b.includes('API keys')));
  assert.ok(r.blockers.some((b) => b.includes('linked account')));
});

test('even a fully configured provider stays blocked in this release (no live transfers, no invented ids)', () => {
  const r = providerReadiness({ provider: 'razorpay_route', routeEnabled: true, hasKeyId: true, hasKeySecret: true, hasRazorpayxAccount: true, operatorsOnboarded: true });
  assert.equal(r.ready, false);
  assert.ok(r.blockers.some((b) => b.includes('not enabled in this release')));
});

test('RazorpayX and unknown providers are blocked too', () => {
  assert.ok(providerReadiness({ ...none, provider: 'razorpayx' }).blockers.some((b) => b.includes('RazorpayX account number')));
  assert.ok(providerReadiness({ ...none, provider: 'bitcoin' }).blockers[0].includes('unknown provider'));
});

test('blocked responses carry a stable code', () => {
  const b = blockedBody('process-settlement', providerReadiness(none));
  assert.equal(b.ok, false);
  assert.equal(b.code, 'blocked_provider_not_configured');
  assert.equal(b.action, 'process-settlement');
});

const dbPay = (o = {}) => ({ razorpay_payment_id: 'pay_1', status: 'captured', amount_cents: 50000, currency_code: 'INR', ...o });
const rpPay = (o = {}) => ({ id: 'pay_1', order_id: 'order_1', amount: 50000, currency: 'INR', status: 'captured', ...o });

test('matching payments produce no findings', () => {
  assert.deepEqual(comparePayments([rpPay()], [dbPay()]), []);
});

test('captured at Razorpay but unknown to us is critical', () => {
  const f = comparePayments([rpPay({ id: 'pay_x' })], [dbPay()]);
  assert.equal(f.length, 1);
  assert.equal(f[0].kind, 'provider_payment_missing_in_db');
});

test('authorized or failed payments at Razorpay are not money in', () => {
  assert.deepEqual(comparePayments([rpPay({ id: 'pay_a', status: 'authorized' }), rpPay({ id: 'pay_f', status: 'failed' })], [dbPay()]), []);
});

test('we think it is captured but Razorpay does not', () => {
  const f = comparePayments([rpPay({ status: 'authorized' })], [dbPay()]);
  assert.equal(f[0].kind, 'db_paid_provider_not_captured');
});

test('captured at Razorpay while we recorded a failure', () => {
  const f = comparePayments([rpPay()], [dbPay({ status: 'failed' })]);
  assert.ok(f.some((x) => x.kind === 'provider_captured_db_not'));
});

test('amount or currency differences are reported', () => {
  assert.equal(comparePayments([rpPay({ amount: 49900 })], [dbPay()])[0].kind, 'payment_amount_mismatch');
  assert.equal(comparePayments([rpPay({ currency: 'USD' })], [dbPay()])[0].kind, 'payment_amount_mismatch');
});

test('a payment simply outside the provider window is not a finding', () => {
  assert.deepEqual(comparePayments([], [dbPay()]), []);
});

test('duplicate captures are money in on our side too', () => {
  assert.deepEqual(comparePayments([rpPay()], [dbPay({ status: 'duplicate_captured' })]), []);
});

test('refund comparison', () => {
  const rp = { id: 'rfnd_1', payment_id: 'pay_1', amount: 40000, status: 'processed' };
  const db = { razorpay_refund_id: 'rfnd_1', status: 'processed', amount_cents: 40000 };
  assert.deepEqual(compareRefunds([rp], [db]), []);
  assert.equal(compareRefunds([rp], [])[0].kind, 'provider_refund_missing_in_db');
  assert.equal(compareRefunds([rp], [{ ...db, status: 'submitted_to_provider' }])[0].kind, 'refund_not_processed_in_db');
  assert.equal(compareRefunds([rp], [{ ...db, amount_cents: 39999 }])[0].kind, 'refund_amount_mismatch');
  assert.equal(compareRefunds([{ ...rp, status: 'pending' }], [db])[0].kind, 'db_refund_not_processed_at_provider');
  assert.deepEqual(compareRefunds([{ ...rp, status: 'pending' }], []), [], 'a pending refund we do not know yet is not reported');
});
