import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PageTitle } from "@/components/ui";
import RouteBuilder from "./route-builder";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function EditRevisionPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: rev } = await supabase
    .from("route_revisions")
    .select("*, route_revision_journeys(*, route_revision_stops(*, location:locations(name))), buses!route_revisions_bus_id_fkey(id, name, registration_number), operators(name)")
    .eq("id", id)
    .maybeSingle();
  if (!rev) notFound();
  const r: any = rev;

  const [{ data: locations }, { data: mains }, prev] = await Promise.all([
    supabase.from("locations").select("id, name, location_code, is_pickup_enabled, is_drop_enabled").eq("is_active", true).order("pickup_order"),
    supabase.from("locations").select("id, name, location_code").eq("is_active", true).eq("is_main_route_enabled", true).order("main_route_order"),
    r.base_revision_id ? supabase.from("route_revisions").select("revision_no").eq("id", r.base_revision_id).maybeSingle() : Promise.resolve({ data: null }),
  ]);

  return (
    <div>
      <Link href={`/bus-routes/${r.buses?.id}`} className="text-sm text-text-secondary hover:text-primary">
        ← {r.buses?.registration_number}
      </Link>
      <div className="mt-2">
        <PageTitle title="Route builder" subtitle="Changes are saved as a draft revision; the live route only changes when you publish." />
      </div>
      <RouteBuilder
        revision={r}
        bus={r.buses}
        operatorName={r.operators?.name ?? ""}
        locations={(locations as any[]) ?? []}
        mains={(mains as any[]) ?? []}
        previousRevisionNo={(prev.data as any)?.revision_no ?? null}
      />
    </div>
  );
}
