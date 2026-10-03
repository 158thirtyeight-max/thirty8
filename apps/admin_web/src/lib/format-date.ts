// Indian date format (dd/mm/yyyy) used everywhere in the admin UI.
const TZ = "Asia/Kolkata";

export function fmtDate(v: string | number | Date): string {
  return new Date(v).toLocaleDateString("en-GB", { timeZone: TZ });
}

export function fmtDateTime(v: string | number | Date): string {
  return new Date(v).toLocaleString("en-GB", { timeZone: TZ, hour12: true });
}
