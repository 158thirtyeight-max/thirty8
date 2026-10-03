import { fmtDateTime } from "@/lib/format-date";
import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Badge, Button, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { SeatLayoutView } from "@/components/seat-layout";
import { assignRoute, reviewBus, reviewBusDocument } from "../actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const DOC_LABELS: Record<string, string> = {
  rc: "Registration Certificate (RC)",
  insurance: "Insurance",
  fitness: "Fitness certificate",
  permit: "Permit",
  puc: "PUC",
  road_tax: "Road / vehicle tax",
  other_transport: "Other transport document",
};

const DAY_LABELS = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

function fmt(ts?: string | null) {
  return ts ? fmtDateTime(ts) : "—";
}
function rupees(cents: number) {
  return `₹${(cents / 100).toLocaleString("en-IN", { minimumFractionDigits: cents % 100 ? 2 : 0 })}`;
}
function clock(baseTime: string, offsetMin: number | null) {
  if (offsetMin === null || offsetMin === undefined) return "—";
  const [h, m] = baseTime.split(":").map(Number);
  const total = h * 60 + m + offsetMin;
  const day = Math.floor(total / 1440);
  const t = ((total % 1440) + 1440) % 1440;
  return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}${day > 0 ? ` (+${day}d)` : ""}`;
}

// Bus photos live in Cloudflare R2; the database stores object keys.
const R2_BASE = (process.env.NEXT_PUBLIC_R2_PUBLIC_URL ?? "").replace(/\/+$/, "");

async function r2Exists(key: string): Promise<boolean> {
  if (!R2_BASE) return false;
  try {
    const res = await fetch(`${R2_BASE}/${key}`, { method: "HEAD", cache: "no-store" });
    return res.ok;
  } catch {
    return false;
  }
}

function PhotoGrid({ keys, alt, found }: { keys?: string[] | null; alt: string; found: Record<string, boolean> }) {
  if (!keys || keys.length === 0) return <p className="text-text-tertiary">Not provided</p>;
  return (
    <div className="grid grid-cols-2 gap-3">
      {keys.map((k) => (
        <div key={k}>
          <a href={`${R2_BASE}/${k}`} target="_blank" rel="noreferrer">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={`${R2_BASE}/${k}`} alt={alt} className="max-h-32 rounded-md" />
          </a>
          <p className={`mt-1 break-all text-[10px] ${found[k] ? "text-success" : "text-error"}`}>
            {found[k] ? "In R2" : "Not found in R2"} · {k.split("/").pop()}
          </p>
        </div>
      ))}
    </div>
  );
}

function isImage(name?: string | null) {
  return /\.(jpe?g|png|webp|gif)$/i.test(name ?? "");
}
function isPdf(name?: string | null) {
  return /\.pdf$/i.test(name ?? "");
}

function Field({ label, value }: { label: string; value: any }) {
  return (
    <div className="flex justify-between gap-4 py-1">
      <dt className="text-text-secondary">{label}</dt>
      <dd className="text-right">{value === null || value === undefined || value === "" ? "—" : String(value)}</dd>
    </div>
  );
}

function Card({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="rounded-xl border border-border bg-surface p-5">
      <p className="mb-3 text-sm font-medium text-text-primary">{title}</p>
      <div className="text-sm">{children}</div>
    </div>
  );
}

function DocReviewForm({ verify, reject }: { verify: (fd: FormData) => Promise<void>; reject: (fd: FormData) => Promise<void> }) {
  return (
    <form className="flex flex-wrap items-center gap-2">
      <input name="reason" placeholder="Reason (required to reject)" className="w-52 rounded-md border border-border bg-background px-2 py-1 text-xs text-text-primary" />
      <button formAction={verify} className="rounded-md bg-success px-2 py-1 text-xs text-white hover:opacity-90">
        Verify
      </button>
      <button formAction={reject} className="rounded-md bg-error px-2 py-1 text-xs text-white hover:opacity-90">
        Reject
      </button>
    </form>
  );
}

export default async function BusDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ error?: string }>;
}) {
  const { id } = await params;
  const { error } = await searchParams;
  const supabase = await createClient();

  const { data: bus } = await supabase.from("buses").select("*, operators(id, name, status)").eq("id", id).single();
  if (!bus) notFound();

  const { data: service } = await supabase
    .from("bus_services")
    .select("*")
    .eq("bus_id", id)
    .order("created_at")
    .limit(1)
    .maybeSingle();

  const routeId = service?.route_id as string | undefined;
  const { data: catalog } = await supabase.from("route_templates").select("id, name").eq("is_active", true).order("name");
  const [
    { data: documents },
    { data: layout },
    { data: boarding },
    { data: dropping },
    { data: rules },
    { data: charges },
    { data: completeness },
    { data: readiness },
    { data: audit },
    { data: srcCity },
    { data: dstCity },
  ] = await Promise.all([
    supabase.from("bus_documents").select("*").eq("bus_id", id).order("created_at"),
    supabase.from("bus_layouts").select("*").eq("bus_id", id).eq("is_active", true).order("version", { ascending: false }).limit(1).maybeSingle(),
    routeId ? supabase.from("boarding_points").select("*").eq("route_id", routeId).eq("is_active", true).order("sequence_no") : Promise.resolve({ data: [] as any[] }),
    routeId ? supabase.from("dropping_points").select("*").eq("route_id", routeId).eq("is_active", true).order("sequence_no") : Promise.resolve({ data: [] as any[] }),
    service ? supabase.from("fare_rules").select("*").eq("service_id", service.id) : Promise.resolve({ data: [] as any[] }),
    service ? supabase.from("fare_charges").select("*").eq("service_id", service.id).eq("active", true) : Promise.resolve({ data: [] as any[] }),
    supabase.rpc("bus_completeness", { p_bus_id: id }),
    supabase.rpc("bus_activation_readiness", { p_bus_id: id }),
    supabase
      .from("audit_logs")
      .select("id, action, actor_profile_id, before, after, created_at")
      .or(`entity_id.eq.${id},after->>bus_id.eq.${id}`)
      .order("created_at", { ascending: false })
      .limit(100),
    service ? supabase.from("locations").select("name").eq("id", service.service_source_city_id).maybeSingle() : Promise.resolve({ data: null as any }),
    service ? supabase.from("locations").select("name").eq("id", service.service_dest_city_id).maybeSingle() : Promise.resolve({ data: null as any }),
  ]);

  const { data: seats } = layout
    ? await supabase.from("seats").select("*").eq("bus_layout_id", layout.id).order("deck").order("row_no").order("col_no")
    : { data: [] as any[] };

  // Names for reviewers and actors.
  const personIds = Array.from(new Set([bus.approved_by, bus.reviewed_by, bus.legacy_reviewed_by, ...(audit ?? []).map((a: any) => a.actor_profile_id)].filter(Boolean)));
  const { data: people } = personIds.length ? await supabase.from("profiles").select("id, full_name, email").in("id", personIds) : { data: [] as any[] };
  const who = (pid?: string | null) => {
    if (!pid) return "—";
    const p = (people ?? []).find((x: any) => x.id === pid);
    return p?.full_name || p?.email || pid.slice(0, 8);
  };

  // Document files are private (R2, or Supabase Storage for older uploads); give the admin short-lived signed links.
  const signed: Record<string, string> = {};
  await Promise.all(
    (documents ?? []).map(async (d: any) => {
      if (d.bucket === "r2") {
        const { data } = await supabase.functions.invoke("r2-document-url", { body: { doc_id: d.id } });
        if (data?.url) signed[d.id] = data.url;
        return;
      }
      const { data } = await supabase.storage.from(d.bucket ?? "bus-documents").createSignedUrl(d.file_path, 600);
      if (data?.signedUrl) signed[d.id] = data.signedUrl;
    }),
  );

  const { data: requirements } = await supabase
    .from("document_requirements")
    .select("doc_type, label, required")
    .eq("scope", "bus")
    .eq("active", true)
    .order("sort_order");
  const uploadedTypes = new Set((documents ?? []).map((d: any) => d.doc_type));
  const notUploaded = (requirements ?? []).filter((r: any) => !uploadedTypes.has(r.doc_type));
  const verifiedCount = (documents ?? []).filter((d: any) => d.status === "verified").length;

  const photoKeys: string[] = [...(bus.exterior_photo_keys ?? []), ...(bus.interior_photo_keys ?? [])];
  const found: Record<string, boolean> = {};
  await Promise.all(photoKeys.map(async (k) => (found[k] = await r2Exists(k))));

  const state: string = bus.is_legacy ? (bus.legacy_migration_status ? `legacy_${bus.legacy_migration_status}` : "legacy") : bus.lifecycle_status;
  const inReview = bus.is_legacy ? ["submitted", "under_review"].includes(bus.legacy_migration_status) : ["submitted", "under_review"].includes(bus.lifecycle_status);
  const startReviewable = bus.is_legacy ? bus.legacy_migration_status === "submitted" : bus.lifecycle_status === "submitted";
  const details = (completeness?.details ?? {}) as Record<string, string[]>;
  const stops = (() => {
    const map = new Map<number, any>();
    for (const p of [...(boarding ?? []), ...(dropping ?? [])]) {
      const s = map.get(p.sequence_no) ?? { seq: p.sequence_no, name: p.name, arrival: p.arrival_offset_min, departure: p.departure_offset_min, boarding: false, dropping: false };
      if (boarding?.some((b: any) => b.id === p.id)) s.boarding = true;
      else s.dropping = true;
      map.set(p.sequence_no, s);
    }
    return Array.from(map.values()).sort((a, b) => a.seq - b.seq);
  })();
  const pointName = (pid: string | null, list: any[] | null) => (pid ? (list ?? []).find((p: any) => p.id === pid)?.name ?? "?" : "Any");
  const missing: string[] = completeness?.missing ?? [];

  return (
    <div>
      <PageTitle title={bus.name || bus.registration_number} subtitle={`${bus.registration_number} · ${String(bus.bus_type).replace(/_/g, " ")} · ${bus.total_seats} seats`} />

      {error && <p className="mb-4 rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{error}</p>}

      <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2">
        <Card title="Status">
          <div className="mb-2 flex flex-wrap items-center gap-2">
            <Badge status={bus.lifecycle_status} />
            {bus.is_legacy && <Badge status="legacy" />}
            {bus.legacy_migration_status && <Badge status={bus.legacy_migration_status} />}
          </div>
          <Field label="Operator" value={bus.operators?.name} />
          <Field label="Setup complete" value={completeness ? `${completeness.percent}%` : undefined} />
          <Field label="Submitted" value={fmt(bus.submitted_at)} />
          <Field label="Last reviewed" value={`${fmt(bus.reviewed_at)} by ${who(bus.reviewed_by)}`} />
          <Field label="Approved" value={bus.approved_at ? `${fmt(bus.approved_at)} by ${who(bus.approved_by)}` : undefined} />
          {bus.legacy_reviewed_at && <Field label="Legacy migration" value={`${fmt(bus.legacy_reviewed_at)} by ${who(bus.legacy_reviewed_by)}`} />}
          <Field label="Activated" value={fmt(bus.activated_at)} />
          {bus.review_reason && <Field label="Latest reason" value={bus.review_reason} />}
          {bus.operators?.id && (
            <p className="mt-2">
              <Link href={`/operators/${bus.operators.id}`} className="text-primary hover:underline">
                View operator →
              </Link>
            </p>
          )}
        </Card>

        <div className="rounded-xl border border-border bg-surface p-5">
          <p className="mb-3 text-sm font-medium text-text-primary">Review actions</p>
          <form className="space-y-3">
            <textarea
              name="reason"
              rows={3}
              placeholder="Reason — required to reject, request changes, or suspend"
              className="w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-text-primary"
            />
            <div className="flex flex-wrap gap-2">
              {startReviewable && (
                <Button type="submit" variant="outline" formAction={reviewBus.bind(null, id, "start_review")}>
                  Start review
                </Button>
              )}
              {inReview && (
                <>
                  <Button type="submit" variant="primary" formAction={reviewBus.bind(null, id, "approve")}>
                    {bus.is_legacy ? "Approve & migrate" : "Approve"}
                  </Button>
                  <Button type="submit" variant="secondary" formAction={reviewBus.bind(null, id, "request_changes")}>
                    Request changes
                  </Button>
                  {!bus.is_legacy && (
                    <Button type="submit" variant="destructive" formAction={reviewBus.bind(null, id, "reject")}>
                      Reject
                    </Button>
                  )}
                </>
              )}
              {["approved", "active"].includes(bus.lifecycle_status) && (
                <Button type="submit" variant="destructive" formAction={reviewBus.bind(null, id, "suspend")}>
                  Suspend bus
                </Button>
              )}
              {(bus.lifecycle_status === "suspended" || (bus.lifecycle_status === "inactive" && !bus.approved_by)) && (
                <Button type="submit" variant="primary" formAction={reviewBus.bind(null, id, "reinstate")}>
                  {bus.lifecycle_status === "suspended" ? "Reinstate" : "Reopen as draft"}
                </Button>
              )}
            </div>
            {bus.is_legacy && !inReview && (
              <p className="text-xs text-text-tertiary">
                Legacy bus: it is running for customers but has not been through the workflow. It will show here for review once the operator submits it. You can
                suspend it at any time.
              </p>
            )}
            {inReview && <p className="text-xs text-text-tertiary">Approval requires every uploaded document verified and the layout, route, fares and schedule to be valid.</p>}
          </form>
          {readiness && !readiness.ready && (state === "approved" || inReview) && (
            <div className="mt-4 text-xs text-text-secondary">
              <p className="mb-1 font-medium text-text-primary">Outstanding items</p>
              <ul className="list-disc space-y-0.5 pl-4">
                {(readiness.blockers as string[]).map((b) => (
                  <li key={b}>{b}</li>
                ))}
              </ul>
            </div>
          )}
        </div>
      </div>

      {missing.length > 0 && (
        <p className="mb-6 rounded-md border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-warning">Missing: {missing.join(" · ")}</p>
      )}

      <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-3">
        <Card title="Vehicle">
          <Field label="Manufacturer" value={bus.manufacturer} />
          <Field label="Model" value={bus.model} />
          <Field label="Manufactured / registered" value={`${bus.manufacturing_year ?? "—"} / ${bus.registration_year ?? "—"}`} />
          <Field label="Chassis no." value={bus.chassis_number} />
          <Field label="Engine no." value={bus.engine_number} />
          <Field label="Capacity" value={bus.total_seats} />
        </Card>
        <Card title={`Exterior photographs (${(bus.exterior_photo_keys ?? []).length})`}>
          <PhotoGrid keys={bus.exterior_photo_keys} alt="Exterior" found={found} />
        </Card>
        <Card title={`Interior photographs (${(bus.interior_photo_keys ?? []).length})`}>
          <PhotoGrid keys={bus.interior_photo_keys} alt="Interior" found={found} />
        </Card>
      </div>

      <SectionHeader title={`Documents (${verifiedCount}/${documents?.length ?? 0} verified)`} />
      <p className="mb-3 text-xs text-text-tertiary">
        Photographs and documents (RC, insurance, permit…) are stored in Cloudflare R2; documents are private and opened through 10-minute signed links. Older uploads may still
        be in Supabase Storage.
      </p>
      <Table>
        <thead>
          <tr>
            <Th>Document</Th>
            <Th>Number / dates</Th>
            <Th>File</Th>
            <Th>Status</Th>
            <Th>Review</Th>
          </tr>
        </thead>
        <tbody>
          {documents?.map((d: any) => {
            const expired = d.expiry_date && new Date(d.expiry_date) < new Date(new Date().toDateString());
            const url = signed[d.id];
            return (
              <tr key={d.id}>
                <Td>{DOC_LABELS[d.doc_type] ?? d.doc_type}</Td>
                <Td>
                  <div>{d.doc_number ?? "—"}</div>
                  <div className="text-xs text-text-tertiary">
                    {d.issue_date ?? "—"} → {d.expiry_date ?? "—"}
                  </div>
                  {expired && <div className="text-xs text-error">Expired</div>}
                </Td>
                <Td>
                  {url ? (
                    <>
                      <a href={url} target="_blank" rel="noreferrer" className="text-primary hover:underline">
                        {d.file_name ?? "Open file"}
                      </a>
                      <details className="mt-1">
                        <summary className="cursor-pointer text-xs text-text-secondary">Preview</summary>
                        {isImage(d.file_name ?? d.file_path) ? (
                          // eslint-disable-next-line @next/next/no-img-element
                          <img src={url} alt={d.file_name ?? "Document"} className="mt-2 max-h-96 rounded-md border border-border" />
                        ) : isPdf(d.file_name ?? d.file_path) ? (
                          <iframe src={url} title={d.file_name ?? "Document"} className="mt-2 h-96 w-72 rounded-md border border-border" />
                        ) : (
                          <p className="mt-2 text-xs text-text-tertiary">No inline preview for this file type; use the link above.</p>
                        )}
                      </details>
                    </>
                  ) : (
                    <span className="text-error">File missing in storage{d.file_name ? ` (${d.file_name})` : ""}</span>
                  )}
                  <div className="text-xs text-text-tertiary">
                    v{d.version} · {d.bucket === "r2" ? "Cloudflare R2" : `Supabase Storage / ${d.bucket ?? "bus-documents"}`}
                  </div>
                </Td>
                <Td>
                  <Badge status={d.status} />
                  {d.rejection_reason && <div className="mt-1 text-xs text-error">{d.rejection_reason}</div>}
                  {d.reviewed_at && <div className="mt-1 text-xs text-text-tertiary">{fmt(d.reviewed_at)} · {who(d.reviewed_by)}</div>}
                </Td>
                <Td>
                  <DocReviewForm verify={reviewBusDocument.bind(null, d.id, id, "verify")} reject={reviewBusDocument.bind(null, d.id, id, "reject")} />
                </Td>
              </tr>
            );
          })}
          {notUploaded.map((r: any) => (
            <tr key={r.doc_type}>
              <Td>{r.label ?? DOC_LABELS[r.doc_type] ?? r.doc_type}</Td>
              <Td>—</Td>
              <Td>
                <span className={r.required ? "text-error" : "text-text-tertiary"}>Not uploaded{r.required ? " (required)" : " (optional)"}</span>
              </Td>
              <Td>—</Td>
              <Td>—</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!documents?.length && !notUploaded.length && <EmptyState message="No documents uploaded." />}

      <div className="mt-8">
        <SectionHeader title="Seat layout" />
        {layout && (seats?.length ?? 0) > 0 ? (
          <div>
            <p className="mb-3 text-sm text-text-secondary">
              {seats!.length} positions · {seats!.filter((s: any) => s.kind === "bookable").length} bookable · capacity {bus.total_seats}
            </p>
            <SeatLayoutView layout={layout} seats={seats ?? []} />
          </div>
        ) : (
          <EmptyState message="No seat layout configured." />
        )}
        {(details.seats ?? []).map((e) => (
          <p key={e} className="mt-1 text-sm text-error">• {e}</p>
        ))}
      </div>

      <div className="mt-8">
        <SectionHeader title="Route" />
        {(bus.is_legacy || ["draft", "changes_requested"].includes(bus.lifecycle_status)) && (
          <form action={assignRoute.bind(null, id)} className="mb-4 flex flex-wrap items-end gap-3 rounded-lg border border-border bg-surface p-3 text-sm">
            <label className="text-xs">
              Assign a route from the catalog
              <select name="template_id" className="mt-1 block rounded-md border border-border bg-background px-2 py-1 text-sm" defaultValue="">
                <option value="">Select…</option>
                {(catalog ?? []).map((r: any) => (
                  <option key={r.id} value={r.id}>{r.name}</option>
                ))}
              </select>
            </label>
            <label className="text-xs">
              Departs
              <input type="time" name="departure_time" defaultValue={service ? String(service.default_departure_time).slice(0, 5) : "06:00"} className="mt-1 block rounded-md border border-border bg-background px-2 py-1 text-sm" />
            </label>
            <div className="flex gap-2 text-xs">
              {DAY_LABELS.slice(1).map((d, i) => (
                <label key={d} className="flex items-center gap-1">
                  <input type="checkbox" name="days" value={i + 1} defaultChecked={service ? (service.operating_days ?? []).includes(i + 1) : true} /> {d}
                </label>
              ))}
            </div>
            <Button type="submit" variant="outline">Assign route</Button>
            <p className="w-full text-xs text-text-tertiary">Replaces the bus&apos;s current route and stops. The operator sees it immediately in their app and can still adjust times.</p>
          </form>
        )}
        {service ? (
          <>
            <p className="mb-3 text-sm text-text-secondary">
              {srcCity?.name ?? "?"} → {dstCity?.name ?? "?"} · departs {String(service.default_departure_time).slice(0, 5)} · journey{" "}
              {service.est_duration_min ? `${Math.floor(service.est_duration_min / 60)}h ${service.est_duration_min % 60}m` : "—"}
            </p>
            <Table>
              <thead>
                <tr>
                  <Th>#</Th>
                  <Th>Stop</Th>
                  <Th>Boarding</Th>
                  <Th>Dropping</Th>
                  <Th>Arrive</Th>
                  <Th>Depart</Th>
                </tr>
              </thead>
              <tbody>
                {stops.map((s: any) => (
                  <tr key={s.seq}>
                    <Td>{s.seq}</Td>
                    <Td>{s.name}</Td>
                    <Td>{s.boarding ? "Yes" : "—"}</Td>
                    <Td>{s.dropping ? "Yes" : "—"}</Td>
                    <Td>{clock(String(service.default_departure_time), s.arrival)}</Td>
                    <Td>{clock(String(service.default_departure_time), s.departure)}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </>
        ) : (
          <EmptyState message="No route configured." />
        )}
        {(details.route ?? []).map((e) => (
          <p key={e} className="mt-1 text-sm text-error">• {e}</p>
        ))}
      </div>

      <div className="mt-8">
        <SectionHeader title="Fares" />
        {rules?.length ? (
          <Table>
            <thead>
              <tr>
                <Th>Seats</Th>
                <Th>From</Th>
                <Th>To</Th>
                <Th>Fare</Th>
              </tr>
            </thead>
            <tbody>
              {rules.map((r: any) => (
                <tr key={r.id}>
                  <Td>
                    {r.seat_type}
                    {r.berth ? ` · ${r.berth}` : ""}
                    {r.seat_category ? ` · ${r.seat_category}` : ""}
                  </Td>
                  <Td>{pointName(r.from_boarding_point_id, boarding)}</Td>
                  <Td>{pointName(r.to_dropping_point_id, dropping)}</Td>
                  <Td>{rupees(r.base_fare_cents)}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        ) : (
          <EmptyState message="No fares configured." />
        )}
        {charges?.length ? (
          <p className="mt-2 text-sm text-text-secondary">
            Extra charges: {charges.map((c: any) => `${c.name} (${c.kind === "flat" ? rupees(c.flat_cents) : `${c.percent}%`})`).join(", ")}
          </p>
        ) : null}
        {(details.fare ?? []).map((e) => (
          <p key={e} className="mt-1 text-sm text-error">• {e}</p>
        ))}
      </div>

      <div className="mt-8">
        <SectionHeader title="Schedule" />
        {service ? (
          <div className="text-sm">
            <p>
              Departs {String(service.default_departure_time).slice(0, 5)} · Operates{" "}
              {(service.operating_days as number[]).length === 7 ? "every day" : (service.operating_days as number[]).map((d) => DAY_LABELS[d]).join(", ")}
            </p>
            <p className="text-text-secondary">
              Booking opens {service.booking_open_days_before} days ahead · closes {service.booking_cutoff_min} min before departure · boarding cut-off{" "}
              {service.boarding_cutoff_min} min · {service.schedule_configured ? "confirmed" : "not yet confirmed"}
            </p>
          </div>
        ) : (
          <EmptyState message="No schedule configured." />
        )}
        {(details.schedule ?? []).map((e) => (
          <p key={e} className="mt-1 text-sm text-error">• {e}</p>
        ))}
      </div>

      <div className="mt-8">
        <SectionHeader title="Activity" />
        <Table>
          <thead>
            <tr>
              <Th>When</Th>
              <Th>Action</Th>
              <Th>By</Th>
              <Th>Detail</Th>
            </tr>
          </thead>
          <tbody>
            {audit?.map((a: any) => (
              <tr key={a.id}>
                <Td>{fmt(a.created_at)}</Td>
                <Td className="font-mono text-xs">{a.action}</Td>
                <Td>{who(a.actor_profile_id)}</Td>
                <Td>
                  {a.after?.reason ?? ""}
                  {a.before?.lifecycle_status && a.after?.lifecycle_status && a.before.lifecycle_status !== a.after.lifecycle_status && (
                    <span className="text-text-tertiary">
                      {a.after?.reason ? " · " : ""}
                      {a.before.lifecycle_status} → {a.after.lifecycle_status}
                    </span>
                  )}
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!audit?.length && <EmptyState message="No recorded activity yet." />}
      </div>
    </div>
  );
}
