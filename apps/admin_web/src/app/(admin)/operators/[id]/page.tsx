import { fmtDateTime } from "@/lib/format-date";
import Link from "next/link";
import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Badge, Button, EmptyState, PageTitle, SectionHeader, Table, Td, Th } from "@/components/ui";
import { reviewMandate, reviewOperator, reviewOperatorDocument, setInsuranceStatus } from "../actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const DOC_LABELS: Record<string, string> = {
  pan_card: "PAN card",
  gst_certificate: "GST certificate",
  id_proof: "Identity / address proof",
  other_registration: "Other registration document",
  cancelled_cheque: "Cancelled cheque",
  bank_additional: "Additional bank document",
};

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
      <dl className="text-sm">{children}</dl>
    </div>
  );
}

function fmt(ts?: string | null) {
  return ts ? fmtDateTime(ts) : "—";
}

/** Verify / reject controls for one document; a reason is required for reject and enforced by the RPC. */
function DocReviewForm({ verify, reject }: { verify: (fd: FormData) => Promise<void>; reject: (fd: FormData) => Promise<void> }) {
  return (
    <form className="flex flex-wrap items-center gap-2">
      <input
        name="reason"
        placeholder="Reason (required to reject)"
        className="w-52 rounded-md border border-border bg-background px-2 py-1 text-xs text-text-primary"
      />
      <button formAction={verify} className="rounded-md bg-success px-2 py-1 text-xs text-white hover:opacity-90">
        Verify
      </button>
      <button formAction={reject} className="rounded-md bg-error px-2 py-1 text-xs text-white hover:opacity-90">
        Reject
      </button>
    </form>
  );
}

export default async function OperatorDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ error?: string }>;
}) {
  const { id } = await params;
  const { error } = await searchParams;
  const supabase = await createClient();

  const { data: operator } = await supabase.from("operators").select("*").eq("id", id).single();
  if (!operator) notFound();

  const [
    { data: profile },
    { data: kyc },
    { data: bank },
    { data: documents },
    { data: mandate },
    { data: insurancePolicies },
    { data: buses },
    { count: vehicleCount },
    { count: routeCount },
    { data: audit },
    { data: completeness },
  ] = await Promise.all([
    supabase.from("operator_profiles").select("*").eq("operator_id", id).maybeSingle(),
    supabase.from("operator_kyc").select("*").eq("operator_id", id).maybeSingle(),
    supabase.from("operator_bank_details").select("*").eq("operator_id", id).maybeSingle(),
    supabase.from("operator_documents").select("*").eq("operator_id", id).order("created_at"),
    supabase.from("operator_payment_mandates").select("*").eq("operator_id", id).maybeSingle(),
    supabase.from("operator_insurance").select("*").eq("operator_id", id).order("created_at", { ascending: false }),
    supabase.from("buses").select("id, name, registration_number, bus_type, status, lifecycle_status, is_legacy").eq("operator_id", id),
    supabase.from("cargo_vehicles").select("id", { count: "exact", head: true }).eq("operator_id", id),
    supabase.from("bus_routes").select("id", { count: "exact", head: true }).eq("operator_id", id),
    supabase
      .from("audit_logs")
      .select("id, action, actor_profile_id, before, after, created_at")
      .or(`entity_id.eq.${id},after->>operator_id.eq.${id}`)
      .order("created_at", { ascending: false })
      .limit(100),
    supabase.rpc("operator_completeness", { p_operator_id: id }),
  ]);

  // Resolve names for reviewers/approvers/actors in one query.
  const personIds = Array.from(
    new Set([operator.approved_by, operator.reviewed_by, ...(audit ?? []).map((a: any) => a.actor_profile_id)].filter(Boolean)),
  );
  const { data: people } = personIds.length
    ? await supabase.from("profiles").select("id, full_name, email").in("id", personIds)
    : { data: [] as any[] };
  const who = (pid?: string | null) => {
    if (!pid) return "—";
    const p = (people ?? []).find((x: any) => x.id === pid);
    return p?.full_name || p?.email || pid.slice(0, 8);
  };

  // Documents are private; the admin gets short-lived signed links.
  const signed: Record<string, string> = {};
  const paths = [...(documents ?? []).map((d: any) => d.file_path), ...(mandate ? [mandate.file_path] : [])];
  await Promise.all(
    paths.map(async (path: string) => {
      const { data } = await supabase.storage.from("operator-documents").createSignedUrl(path, 600);
      if (data?.signedUrl) signed[path] = data.signedUrl;
    }),
  );

  const app = operator.application_status as string;
  const inReview = app === "submitted" || app === "under_review";
  const pct = completeness?.percent as number | undefined;

  return (
    <div>
      <PageTitle title={operator.name} subtitle={operator.legal_name} />

      {error && <p className="mb-4 rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{error}</p>}

      <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2">
        <Card title="Status">
          <div className="mb-2 flex items-center gap-2">
            <Badge status={app} />
            <Badge status={operator.status} />
            <span className="text-sm capitalize text-text-secondary">{operator.business_type}</span>
          </div>
          <Field label="Completeness" value={pct === undefined ? undefined : `${pct}%`} />
          <Field label="Submitted" value={fmt(operator.submitted_at)} />
          <Field label="Last reviewed" value={`${fmt(operator.reviewed_at)} by ${who(operator.reviewed_by)}`} />
          <Field label="Approved" value={operator.approved_at ? `${fmt(operator.approved_at)} by ${who(operator.approved_by)}` : undefined} />
          {operator.review_reason && <Field label="Latest reason" value={operator.review_reason} />}
          <Field label="Buses / Cargo vehicles / Routes" value={`${buses?.length ?? 0} / ${vehicleCount ?? 0} / ${routeCount ?? 0}`} />
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
              {app === "submitted" && (
                <Button type="submit" variant="outline" formAction={reviewOperator.bind(null, id, "start_review")}>
                  Start review
                </Button>
              )}
              {inReview && (
                <>
                  <Button type="submit" variant="primary" formAction={reviewOperator.bind(null, id, "approve")}>
                    Approve
                  </Button>
                  <Button type="submit" variant="secondary" formAction={reviewOperator.bind(null, id, "request_changes")}>
                    Request changes
                  </Button>
                  <Button type="submit" variant="destructive" formAction={reviewOperator.bind(null, id, "reject")}>
                    Reject
                  </Button>
                </>
              )}
              {operator.status === "approved" && (
                <Button type="submit" variant="destructive" formAction={reviewOperator.bind(null, id, "suspend")}>
                  Suspend operator
                </Button>
              )}
              {operator.status === "suspended" && (
                <Button type="submit" variant="primary" formAction={reviewOperator.bind(null, id, "reinstate")}>
                  Reinstate
                </Button>
              )}
            </div>
            {!inReview && operator.status === "pending" && (
              <p className="text-xs text-text-tertiary">
                {app === "draft" ? "The operator has not submitted the application yet." : "Waiting for the operator to resubmit after the requested changes."}
              </p>
            )}
            {inReview && (
              <p className="text-xs text-text-tertiary">Approval requires every uploaded document and the payment mandate to be verified first.</p>
            )}
          </form>
        </div>
      </div>

      <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-3">
        <Card title="Business">
          <Field label="Owner" value={profile?.owner_name} />
          <Field label="Entity type" value={profile?.business_type_detail} />
          <Field label="Mobile" value={operator.contact_phone} />
          <Field label="Email" value={operator.contact_email} />
          <Field label="Address" value={profile?.address} />
          <Field label="Contact address" value={profile?.contact_address} />
          <Field label="City / District" value={[profile?.city, profile?.district].filter(Boolean).join(" / ")} />
          <Field label="State / PIN" value={[profile?.state, profile?.pin_code].filter(Boolean).join(" - ")} />
        </Card>
        <Card title="KYC & GST">
          <Field label="PAN" value={kyc?.pan_number} />
          <Field label="GST registered" value={kyc?.gst_registered === null || kyc?.gst_registered === undefined ? undefined : kyc.gst_registered ? "Yes" : "No"} />
          <Field label="GSTIN" value={kyc?.gstin} />
        </Card>
        <Card title="Bank & payout">
          <Field label="Holder" value={bank?.account_holder_name} />
          <Field label="Bank / Branch" value={[bank?.bank_name, bank?.branch_name].filter(Boolean).join(" / ")} />
          <Field label="Account no." value={bank?.account_number} />
          <Field label="IFSC" value={bank?.ifsc} />
          <Field label="MICR" value={bank?.micr} />
          <Field label="Type" value={bank?.account_type} />
        </Card>
      </div>

      <SectionHeader title="Documents" />
      <Table>
        <thead>
          <tr>
            <Th>Document</Th>
            <Th>File</Th>
            <Th>Status</Th>
            <Th>Reviewed</Th>
            <Th>Review</Th>
          </tr>
        </thead>
        <tbody>
          {documents?.map((d: any) => (
            <tr key={d.id}>
              <Td>{DOC_LABELS[d.doc_type] ?? d.doc_type}</Td>
              <Td>
                {signed[d.file_path] ? (
                  <a href={signed[d.file_path]} target="_blank" rel="noreferrer" className="text-primary hover:underline">
                    {d.file_name ?? "View"}
                  </a>
                ) : (
                  d.file_name ?? "—"
                )}
                <div className="text-xs text-text-tertiary">v{d.version}</div>
              </Td>
              <Td>
                <Badge status={d.status} />
                {d.rejection_reason && <div className="mt-1 text-xs text-error">{d.rejection_reason}</div>}
              </Td>
              <Td>
                {d.reviewed_at ? (
                  <>
                    <div>{fmt(d.reviewed_at)}</div>
                    <div className="text-xs text-text-tertiary">by {who(d.reviewed_by)}</div>
                  </>
                ) : (
                  "—"
                )}
              </Td>
              <Td>
                <DocReviewForm
                  verify={reviewOperatorDocument.bind(null, d.id, id, "verify")}
                  reject={reviewOperatorDocument.bind(null, d.id, id, "reject")}
                />
              </Td>
            </tr>
          ))}
          <tr>
            <Td>Payment mandate</Td>
            <Td>
              {mandate ? (
                signed[mandate.file_path] ? (
                  <a href={signed[mandate.file_path]} target="_blank" rel="noreferrer" className="text-primary hover:underline">
                    {mandate.file_name ?? "View"}
                  </a>
                ) : (
                  mandate.file_name ?? "—"
                )
              ) : (
                "Not uploaded"
              )}
              {mandate && <div className="text-xs text-text-tertiary">v{mandate.version} · {mandate.template_version}</div>}
            </Td>
            <Td>
              {mandate ? <Badge status={mandate.status} /> : "—"}
              {mandate?.rejection_reason && <div className="mt-1 text-xs text-error">{mandate.rejection_reason}</div>}
            </Td>
            <Td>
              {mandate?.reviewed_at ? (
                <>
                  <div>{fmt(mandate.reviewed_at)}</div>
                  <div className="text-xs text-text-tertiary">by {who(mandate.reviewed_by)}</div>
                </>
              ) : (
                "—"
              )}
            </Td>
            <Td>
              {mandate && (
                <DocReviewForm verify={reviewMandate.bind(null, id, "verify")} reject={reviewMandate.bind(null, id, "reject")} />
              )}
            </Td>
          </tr>
        </tbody>
      </Table>
      {!documents?.length && !mandate && <EmptyState message="No documents uploaded yet." />}

      <div className="mt-8">
        <SectionHeader title="Buses" />
        <Table>
          <thead>
            <tr>
              <Th>Registration</Th>
              <Th>Type</Th>
              <Th>Status</Th>
            </tr>
          </thead>
          <tbody>
            {buses?.map((b: any) => (
              <tr key={b.id}>
                <Td>
                  <Link href={`/buses/${b.id}`} className="text-primary hover:underline">
                    {b.name || b.registration_number}
                  </Link>
                  {b.name && <div className="text-xs text-text-tertiary">{b.registration_number}</div>}
                </Td>
                <Td>{b.bus_type}</Td>
                <Td>
                  <div className="flex flex-wrap gap-1">
                    <Badge status={b.lifecycle_status ?? b.status} />
                    {b.is_legacy && <Badge status="legacy" />}
                  </div>
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!buses?.length && <EmptyState message="No buses yet." />}
      </div>

      <div className="mt-8">
        <SectionHeader title="Insurance policies" />
        <Table>
          <thead>
            <tr>
              <Th>Provider</Th>
              <Th>Policy #</Th>
              <Th>Valid</Th>
              <Th>Status</Th>
              <Th>Verify</Th>
            </tr>
          </thead>
          <tbody>
            {insurancePolicies?.map((policy: any) => (
              <tr key={policy.id}>
                <Td>{policy.insurance_provider}</Td>
                <Td>{policy.policy_number}</Td>
                <Td>
                  {policy.valid_from} → {policy.valid_until}
                </Td>
                <Td>
                  <Badge status={policy.status} />
                  {policy.rejection_reason && <div className="mt-1 text-xs text-error">{policy.rejection_reason}</div>}
                </Td>
                <Td>
                  {policy.status === "pending" && (
                    <DocReviewForm
                      verify={setInsuranceStatus.bind(null, policy.id, id, "verified")}
                      reject={setInsuranceStatus.bind(null, policy.id, id, "rejected")}
                    />
                  )}
                </Td>
              </tr>
            ))}
          </tbody>
        </Table>
        {!insurancePolicies?.length && <EmptyState message="No insurance policies uploaded yet." />}
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
                  {a.before?.status && a.after?.status && a.before.status !== a.after.status && (
                    <span className="text-text-tertiary">
                      {a.after?.reason ? " · " : ""}
                      {a.before.status} → {a.after.status}
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
