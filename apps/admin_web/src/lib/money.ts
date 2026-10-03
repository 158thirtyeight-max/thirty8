/** Paise (integer) -> "₹1,234.50". Money is always integer paise in the database; this is display only. */
export function inr(cents: number | string | null | undefined): string {
  if (cents === null || cents === undefined || cents === "") return "—";
  const n = Number(cents);
  if (!Number.isFinite(n)) return "—";
  const sign = n < 0 ? "-" : "";
  const abs = Math.abs(n);
  return `${sign}₹${(abs / 100).toLocaleString("en-IN", { minimumFractionDigits: abs % 100 ? 2 : 0, maximumFractionDigits: 2 })}`;
}

/** Basis points -> "80%" / "12.5%". */
export function bpsToPct(bps: number | null | undefined): string {
  if (bps === null || bps === undefined) return "—";
  return `${bps / 100}%`;
}

/** A percentage typed by an admin ("12.5") -> integer basis points. Returns null when invalid. */
export function pctToBps(value: string | null | undefined): number | null {
  const n = Number((value ?? "").trim());
  if (!Number.isFinite(n) || n < 0 || n > 100) return null;
  return Math.round(n * 100);
}

/** Rupees typed by an admin ("450" / "450.50") -> integer paise. Returns null when invalid. */
export function rupeesToCents(value: string | null | undefined): number | null {
  const raw = (value ?? "").trim().replace(/,/g, "");
  if (!/^\d+(\.\d{1,2})?$/.test(raw)) return null;
  return Math.round(Number(raw) * 100);
}
