// Unit tests for the pure payment/refund decision logic shared by the edge functions.
// Run: node --test supabase/tests/edge/razorpay.test.mjs   (Node >= 22.18 strips the TS types)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { decidePayment, findRefundByOurId, isDefinitiveRefusal } from '../../functions/_shared/razorpay.ts';

const expected = { paymentId: 'pay_1', razorpayOrderId: 'order_1', amountCents: 50000, currency: 'INR' };
const pay = (o = {}) => ({ id: 'pay_1', order_id: 'order_1', amount: 50000, currency: 'INR', status: 'captured', ...o });

test('captured payment is confirmed using the provider data', () => {
  assert.deepEqual(decidePayment(pay(), expected), { action: 'confirm' });
});
test('captured with a wrong amount is still handed to the database (it queues a refund)', () => {
  assert.deepEqual(decidePayment(pay({ amount: 100 }), expected), { action: 'confirm' });
});
test('payment for a different Razorpay order is rejected', () => {
  assert.equal(decidePayment(pay({ order_id: 'order_other' }), expected).action, 'reject');
});
test('payment id mismatch is rejected', () => {
  assert.equal(decidePayment(pay({ id: 'pay_x' }), expected).action, 'reject');
});
test('authorized with matching amount/currency is captured', () => {
  assert.deepEqual(decidePayment(pay({ status: 'authorized' }), expected), { action: 'capture' });
});
test('authorized with a different amount or currency is never captured', () => {
  assert.equal(decidePayment(pay({ status: 'authorized', amount: 49999 }), expected).action, 'reject');
  assert.equal(decidePayment(pay({ status: 'authorized', currency: 'USD' }), expected).action, 'reject');
});
test('failed payment reports its reason', () => {
  assert.deepEqual(decidePayment(pay({ status: 'failed', error_description: 'declined' }), expected), { action: 'failed', reason: 'declined' });
});
test('created / unknown status waits', () => {
  assert.equal(decidePayment(pay({ status: 'created' }), expected).action, 'wait');
});
test('refund lookup finds only our own refund row by notes.refund_id', () => {
  const refunds = [
    { id: 'rfnd_a', payment_id: 'pay_1', amount: 1, status: 'processed', notes: [] },
    { id: 'rfnd_b', payment_id: 'pay_1', amount: 1, status: 'pending', notes: { refund_id: 'ours' } },
    { id: 'rfnd_c', payment_id: 'pay_1', amount: 1, status: 'pending', notes: null },
  ];
  assert.equal(findRefundByOurId(refunds, 'ours')?.id, 'rfnd_b');
  assert.equal(findRefundByOurId(refunds, 'nope'), undefined);
});
test('only 4xx (not 408/429) is a definitive refusal', () => {
  assert.equal(isDefinitiveRefusal(400), true);
  assert.equal(isDefinitiveRefusal(422), true);
  assert.equal(isDefinitiveRefusal(408), false);
  assert.equal(isDefinitiveRefusal(429), false);
  assert.equal(isDefinitiveRefusal(500), false);
  assert.equal(isDefinitiveRefusal(504), false);
});
