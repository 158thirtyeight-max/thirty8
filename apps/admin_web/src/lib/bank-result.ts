import { parseCsv } from "./csv";

export type BankRow = {
  reference: string;
  account?: string;
  amount?: string;
  utr?: string;
  status: string;
  failure_reason?: string;
  paid_on?: string;
};

const norm = (h: string) => h.toLowerCase().replace(/[^a-z0-9]/g, "");

// Bank result files differ by bank/product. Headers are matched loosely; the SBI layout is NOT confirmed,
// so the preview step (which validates every row against our batches) is the real safety net.
const ALIASES: Record<keyof BankRow, string[]> = {
  reference: ["reference", "narration", "batchreference", "customerreference", "paymentreference", "ref", "remarks"],
  account: ["account", "accountnumber", "accountno", "beneficiaryaccount", "beneficiaryaccountnumber"],
  amount: ["amount", "amountinr", "paidamount", "debitamount", "transactionamount"],
  utr: ["utr", "utrnumber", "utrno", "bankreference", "bankreferencenumber", "transactionreference", "transactionid"],
  status: ["status", "paymentstatus", "transactionstatus", "result"],
  failure_reason: ["failurereason", "reason", "rejectionreason", "errordescription", "statusdescription"],
  paid_on: ["paidon", "paymentdate", "valuedate", "transactiondate", "date", "processeddate"],
};

export function parseBankResult(text: string): { rows: BankRow[]; error?: string; ignoredColumns: string[] } {
  const grid = parseCsv(text);
  if (grid.length < 2) return { rows: [], error: "The file has no data rows.", ignoredColumns: [] };
  const header = grid[0].map(norm);
  const index: Partial<Record<keyof BankRow, number>> = {};
  const used = new Set<number>();
  (Object.keys(ALIASES) as (keyof BankRow)[]).forEach((key) => {
    let i = header.findIndex((h, idx) => !used.has(idx) && ALIASES[key].includes(h));
    // banks name this column many ways ("Beneficiary Account No.", "Cr Account"...): fall back to any header mentioning it
    if (i < 0 && key === "account") i = header.findIndex((h, idx) => !used.has(idx) && h.includes("account"));
    if (i >= 0) { index[key] = i; used.add(i); }
  });
  const missing = (["reference", "amount", "status"] as const).filter((k) => index[k] === undefined);
  const ignoredColumns = grid[0].filter((_, i) => !used.has(i));
  if (missing.length) {
    return { rows: [], error: `Could not find the required column(s): ${missing.join(", ")}. Found: ${grid[0].join(", ")}`, ignoredColumns };
  }
  const rows: BankRow[] = grid.slice(1).map((r) => {
    const get = (k: keyof BankRow) => (index[k] === undefined ? undefined : (r[index[k] as number] ?? "").trim() || undefined);
    return {
      reference: get("reference") ?? "",
      account: get("account"),
      amount: get("amount")?.replace(/,/g, ""),
      utr: get("utr"),
      status: get("status") ?? "",
      failure_reason: get("failure_reason"),
      paid_on: normaliseDate(get("paid_on")),
    };
  });
  return { rows, ignoredColumns };
}

/** dd/mm/yyyy, dd-mm-yyyy or yyyy-mm-dd -> yyyy-mm-dd (anything else is dropped rather than guessed). */
export function normaliseDate(v: string | undefined): string | undefined {
  if (!v) return undefined;
  const iso = /^(\d{4})-(\d{2})-(\d{2})/.exec(v);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
  const dmy = /^(\d{1,2})[/-](\d{1,2})[/-](\d{4})/.exec(v);
  if (dmy) return `${dmy[3]}-${dmy[2].padStart(2, "0")}-${dmy[1].padStart(2, "0")}`;
  return undefined;
}
