import type { NextRequest } from "next/server";
import { requirePlatformAdmin } from "@/lib/auth";

/** Downloads an immutable settlement file. Every download is recorded in the audit log by the database. */
export async function GET(_req: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const { supabase } = await requirePlatformAdmin();
  const { id } = await ctx.params;
  const { data, error } = await supabase.rpc("admin_get_settlement_export", { p_export_id: id });
  if (error || !data) {
    return new Response(error?.message ?? "Export not found", { status: error ? 403 : 404 });
  }
  const file = data as { file_name: string; content: string; sha256: string; template_confirmed: boolean };
  return new Response(file.content, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="${file.file_name}"`,
      "X-Content-SHA256": file.sha256,
      "X-Template-Confirmed": String(file.template_confirmed),
      "Cache-Control": "no-store",
    },
  });
}
