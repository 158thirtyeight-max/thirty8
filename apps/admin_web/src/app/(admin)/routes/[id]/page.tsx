import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PageTitle } from "@/components/ui";
import RouteEditor from "../route-editor";

/* eslint-disable @typescript-eslint/no-explicit-any */

export default async function RoutePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: cities } = await supabase.from("main_locations").select("id, name").eq("is_active", true).order("display_order");

  let route: any = null;
  if (id !== "new") {
    const { data } = await supabase.from("route_templates").select("*, stops:route_template_stops(*)").eq("id", id).maybeSingle();
    if (!data) notFound();
    data.stops.sort((a: any, b: any) => a.sequence_no - b.sequence_no);
    route = data;
  }

  return (
    <div>
      <PageTitle title={route ? route.name : "Add route"} subtitle="Stop times are minutes after the origin departs, so the same route works for any departure time." />
      <RouteEditor cities={cities ?? []} route={route} />
    </div>
  );
}
