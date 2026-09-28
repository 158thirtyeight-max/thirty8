import { notFound } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { Badge, PageTitle, Table, Td, Th } from "@/components/ui";
import { setInsuranceStatus, setOperatorStatus } from "../actions";

export default async function OperatorDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await createClient();

  const { data: operator } = await supabase.from("operators").select("*").eq("id", id).single();
  if (!operator) notFound();

  const [{ data: insurancePolicies }, { count: busCount }, { count: vehicleCount }, { count: routeCount }] = await Promise.all([
    supabase.from("operator_insurance").select("*").eq("operator_id", id).order("created_at", { ascending: false }),
    supabase.from("buses").select("id", { count: "exact", head: true }).eq("operator_id", id),
    supabase.from("cargo_vehicles").select("id", { count: "exact", head: true }).eq("operator_id", id),
    supabase.from("bus_routes").select("id", { count: "exact", head: true }).eq("operator_id", id),
  ]);

  return (
    <div>
      <PageTitle title={operator.name} subtitle={operator.legal_name} />

      <div className="mb-6 grid grid-cols-1 gap-4 md:grid-cols-2">
        <div className="rounded-xl border border-slate-800 bg-slate-900 p-5">
          <div className="mb-3 flex items-center justify-between">
            <Badge status={operator.status} />
            <span className="text-sm capitalize text-slate-400">{operator.business_type}</span>
          </div>
          <dl className="space-y-1 text-sm">
            <div className="flex justify-between">
              <dt className="text-slate-400">Contact</dt>
              <dd>{operator.contact_email} · {operator.contact_phone}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-slate-400">Buses</dt>
              <dd>{busCount ?? 0}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-slate-400">Cargo vehicles</dt>
              <dd>{vehicleCount ?? 0}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-slate-400">Routes</dt>
              <dd>{routeCount ?? 0}</dd>
            </div>
            <div className="flex justify-between">
              <dt className="text-slate-400">Applied</dt>
              <dd>{new Date(operator.created_at).toLocaleString()}</dd>
            </div>
          </dl>
        </div>

        <div className="rounded-xl border border-slate-800 bg-slate-900 p-5">
          <p className="mb-3 text-sm text-slate-400">Actions</p>
          <div className="flex flex-wrap gap-2">
            {operator.status !== "approved" && (
              <form action={setOperatorStatus.bind(null, id, "approved")}>
                <button className="rounded-lg bg-emerald-700 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-600">Approve</button>
              </form>
            )}
            {operator.status !== "rejected" && (
              <form action={setOperatorStatus.bind(null, id, "rejected")}>
                <button className="rounded-lg bg-red-800 px-3 py-2 text-sm font-medium text-white hover:bg-red-700">Reject</button>
              </form>
            )}
            {operator.status === "approved" && (
              <form action={setOperatorStatus.bind(null, id, "suspended")}>
                <button className="rounded-lg bg-amber-800 px-3 py-2 text-sm font-medium text-white hover:bg-amber-700">Suspend</button>
              </form>
            )}
            {operator.status === "suspended" && (
              <form action={setOperatorStatus.bind(null, id, "approved")}>
                <button className="rounded-lg bg-emerald-700 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-600">Reinstate</button>
              </form>
            )}
          </div>
        </div>
      </div>

      <h3 className="mb-3 text-sm font-medium text-slate-300">Insurance policies</h3>
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
          {insurancePolicies?.map((policy) => (
            <tr key={policy.id}>
              <Td>{policy.insurance_provider}</Td>
              <Td>{policy.policy_number}</Td>
              <Td>
                {policy.valid_from} → {policy.valid_until}
              </Td>
              <Td>
                <Badge status={policy.status} />
              </Td>
              <Td>
                {policy.status === "pending" && (
                  <div className="flex gap-2">
                    <form action={setInsuranceStatus.bind(null, policy.id, id, "verified", undefined)}>
                      <button className="rounded-md bg-emerald-700 px-2 py-1 text-xs text-white hover:bg-emerald-600">Verify</button>
                    </form>
                    <form action={setInsuranceStatus.bind(null, policy.id, id, "rejected", "Does not meet requirements")}>
                      <button className="rounded-md bg-red-800 px-2 py-1 text-xs text-white hover:bg-red-700">Reject</button>
                    </form>
                  </div>
                )}
              </Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!insurancePolicies?.length && <p className="mt-2 text-sm text-slate-500">No insurance policies uploaded yet.</p>}
    </div>
  );
}
