import { redirect } from "next/navigation";

/** Trimmed text field from a form, or null when empty. */
export function text(formData: FormData, key: string): string | null {
  const v = formData.get(key);
  const s = typeof v === "string" ? v.trim() : "";
  return s === "" ? null : s;
}

/** Back to a page with a failure message (the page renders ?error=...). Never throws a crash page at the admin. */
export function fail(path: string, message: string): never {
  const sep = path.includes("?") ? "&" : "?";
  redirect(`${path}${sep}error=${encodeURIComponent(message)}`);
}

/** Back to a page with a success note (rendered as ?ok=...). */
export function ok(path: string, message: string): never {
  const sep = path.includes("?") ? "&" : "?";
  redirect(`${path}${sep}ok=${encodeURIComponent(message)}`);
}

/** PostgREST wraps database errors; keep the human part (our RPCs raise "code: sentence"). */
export function cleanError(message: string): string {
  return message.replace(/^.*?ERROR:\s*/, "");
}

export const inputClass = "rounded-md border border-border bg-surface px-3 py-2 text-sm text-text-primary";
