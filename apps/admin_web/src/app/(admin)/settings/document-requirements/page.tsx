import { createClient } from "@/lib/supabase/server";
import { Button, EmptyState, PageTitle, SectionHeader } from "@/components/ui";
import { createRequirement, updateRequirement } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const inputClass = "w-full rounded-md border border-border bg-background px-2 py-1 text-sm text-text-primary";

function Row({ r }: { r: any }) {
  return (
    <form action={updateRequirement.bind(null, r.id)} className="grid grid-cols-1 gap-3 rounded-lg border border-border bg-surface p-4 md:grid-cols-12">
      <div className="md:col-span-3">
        <p className="text-xs text-text-tertiary">
          {r.scope} · {r.doc_type}
          {r.scope === "operator" ? ` · step: ${r.step}` : ""}
        </p>
        <input name="label" defaultValue={r.label} className={inputClass} />
      </div>
      <div className="flex items-center gap-4 text-sm md:col-span-3">
        <label className="flex items-center gap-1">
          <input type="checkbox" name="required" defaultChecked={r.required} /> Required
        </label>
        <label className="flex items-center gap-1">
          <input type="checkbox" name="active" defaultChecked={r.active} /> Active
        </label>
        <label className="flex items-center gap-1">
          <input type="checkbox" name="has_expiry" defaultChecked={r.has_expiry} /> Expiry
        </label>
      </div>
      <div className="md:col-span-1">
        <input name="sort_order" type="number" defaultValue={r.sort_order} className={inputClass} aria-label="Sort order" />
      </div>
      <div className="md:col-span-4">
        <input name="condition" defaultValue={JSON.stringify(r.condition ?? {})} className={`${inputClass} font-mono text-xs`} aria-label="Condition" />
      </div>
      <div className="md:col-span-1">
        <Button type="submit" variant="outline" className="w-full">
          Save
        </Button>
      </div>
    </form>
  );
}

export default async function DocumentRequirementsPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const { error } = await searchParams;
  const supabase = await createClient();
  const { data: requirements } = await supabase.from("document_requirements").select("*").order("scope").order("sort_order");

  const operator = (requirements ?? []).filter((r: any) => r.scope === "operator");
  const bus = (requirements ?? []).filter((r: any) => r.scope === "bus");

  return (
    <div className="space-y-8">
      <PageTitle title="Document requirements" subtitle="What operators and buses must provide. Nothing here is hard-coded in the apps." />

      {error && <p className="rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{error}</p>}

      <div className="max-w-3xl space-y-1 text-sm text-text-secondary">
        <p>
          A <strong>required</strong> requirement blocks submission until it is provided. <strong>Condition</strong> limits when it applies, as JSON:
        </p>
        <ul className="list-disc pl-5">
          <li>
            Operators: <code>{`{"gst_registered": true}`}</code> (only GST-registered operators), <code>{`{"business_type_in": ["cargo","both"]}`}</code>
          </li>
          <li>
            Buses: <code>{`{"bus_type_in": ["ac_sleeper"]}`}</code>, <code>{`{"bus_type_not_in": ["non_ac_seater"]}`}</code>
          </li>
        </ul>
        <p>Leave it as {"{}"} to apply to everyone. Changes take effect at the next submission or approval check.</p>
      </div>

      <section className="space-y-2">
        <SectionHeader title="Operator documents" />
        {operator.map((r: any) => (
          <Row key={r.id} r={r} />
        ))}
        {!operator.length && <EmptyState message="No operator requirements." />}
      </section>

      <section className="space-y-2">
        <SectionHeader title="Bus documents" />
        {bus.map((r: any) => (
          <Row key={r.id} r={r} />
        ))}
        {!bus.length && <EmptyState message="No bus requirements." />}
      </section>

      <section>
        <SectionHeader title="Add a requirement" />
        <form action={createRequirement} className="grid grid-cols-1 gap-3 rounded-lg border border-border bg-surface p-4 md:grid-cols-6">
          <select name="scope" className={inputClass} defaultValue="bus">
            <option value="bus">Bus</option>
            <option value="operator">Operator</option>
          </select>
          <input name="doc_type" placeholder="doc_type (e.g. speed_governor)" className={inputClass} />
          <input name="label" placeholder="Label shown to the operator" className={`${inputClass} md:col-span-2`} />
          <input name="condition" placeholder='Condition JSON, e.g. {"bus_type_in":["ac_sleeper"]}' className={`${inputClass} font-mono text-xs md:col-span-2`} />
          <div className="flex items-center gap-4 text-sm md:col-span-4">
            <label className="flex items-center gap-1">
              <input type="checkbox" name="required" defaultChecked /> Required
            </label>
            <label className="flex items-center gap-1">
              <input type="checkbox" name="active" defaultChecked /> Active
            </label>
            <label className="flex items-center gap-1">
              <input type="checkbox" name="has_expiry" /> Has expiry date
            </label>
            <label className="flex items-center gap-1">
              Order <input name="sort_order" type="number" defaultValue={100} className="w-20 rounded-md border border-border bg-background px-2 py-1" />
            </label>
          </div>
          <Button type="submit" className="md:col-span-2">
            Add requirement
          </Button>
        </form>
        <p className="mt-2 text-xs text-text-tertiary">
          Operator requirements added here appear on the KYC step of onboarding. New bus requirements appear in each bus&apos;s documents stage.
        </p>
      </section>
    </div>
  );
}
