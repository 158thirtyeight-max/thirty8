/* eslint-disable @typescript-eslint/no-require-imports */
// Unit tests for the finance helpers (money, CSV, bank-result parsing).
// Run: npm run test:lib   (compiles the three files with tsc, then runs node --test)
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { inr, bpsToPct, pctToBps, rupeesToCents } = require("../.test-build/money.js");
const { toCsv, parseCsv } = require("../.test-build/csv.js");
const { parseBankResult, normaliseDate } = require("../.test-build/bank-result.js");

test("money formatting is integer-paise safe", () => {
  assert.equal(inr(50000), "₹500");
  assert.equal(inr(33333), "₹333.33");
  assert.equal(inr(-4500), "-₹45");
  assert.equal(inr(null), "—");
  assert.equal(bpsToPct(8000), "80%");
  assert.equal(bpsToPct(1250), "12.5%");
});

test("admin-typed percentages and rupees become integers, invalid input becomes null", () => {
  assert.equal(pctToBps("80"), 8000);
  assert.equal(pctToBps("12.5"), 1250);
  assert.equal(pctToBps("0"), 0);
  assert.equal(pctToBps("100.01"), null);
  assert.equal(pctToBps("-1"), null);
  assert.equal(pctToBps("abc"), null);
  assert.equal(rupeesToCents("450"), 45000);
  assert.equal(rupeesToCents("1,234.50"), 123450);
  assert.equal(rupeesToCents("10.999"), null);
  assert.equal(rupeesToCents(""), null);
});

test("CSV round-trips quotes, commas and newlines", () => {
  const text = toCsv(["a", "b"], [["x,y", 'he said "hi"'], ["line1\nline2", 5]]);
  const rows = parseCsv(text);
  assert.deepEqual(rows[0], ["a", "b"]);
  assert.deepEqual(rows[1], ["x,y", 'he said "hi"']);
  assert.deepEqual(rows[2], ["line1\nline2", "5"]);
});

test("CSV export defuses spreadsheet formulas but keeps plain negative numbers", () => {
  const text = toCsv(["v"], [["=HYPERLINK(\"http://x\")"], ["-5"], [-5], ["@cmd"]]);
  const rows = parseCsv(text);
  assert.ok(rows[1][0].startsWith("'="));
  assert.equal(rows[2][0], "-5");
  assert.equal(rows[3][0], "-5");
  assert.ok(rows[4][0].startsWith("'@"));
});

test("CSV parser handles CRLF, BOM and blank lines", () => {
  assert.deepEqual(parseCsv("﻿a,b\r\n1,2\r\n\r\n3,4"), [["a", "b"], ["1", "2"], ["3", "4"]]);
});

test("bank result: headers are matched loosely and amounts cleaned", () => {
  const csv = "Narration,Beneficiary Account No,Amount (INR),UTR Number,Payment Status,Value Date\nST-AB12CD34,XXXXXXXX9012,\"1,450.00\",SBIN26277000001,SUCCESS,03/10/2026\n";
  const r = parseBankResult(csv);
  assert.equal(r.error, undefined);
  assert.deepEqual(r.rows[0], { reference: "ST-AB12CD34", account: "XXXXXXXX9012", amount: "1450.00", utr: "SBIN26277000001", status: "SUCCESS", failure_reason: undefined, paid_on: "2026-10-03" });
});

test("bank result: missing required columns is reported, not guessed", () => {
  const r = parseBankResult("foo,bar\n1,2\n");
  assert.ok(r.error && r.error.includes("reference") && r.error.includes("amount") && r.error.includes("status"));
  assert.equal(r.rows.length, 0);
});

test("bank result: empty file and unknown columns", () => {
  assert.ok(parseBankResult("reference,amount,status\n").error);
  const r = parseBankResult("reference,amount,status,branch\nST-1,10,failed,Port Blair\n");
  assert.deepEqual(r.ignoredColumns, ["branch"]);
});

test("dates: only unambiguous formats are accepted", () => {
  assert.equal(normaliseDate("2026-10-03"), "2026-10-03");
  assert.equal(normaliseDate("3/10/2026"), "2026-10-03");
  assert.equal(normaliseDate("03-10-2026"), "2026-10-03");
  assert.equal(normaliseDate("Oct 3"), undefined);
  assert.equal(normaliseDate(undefined), undefined);
});
