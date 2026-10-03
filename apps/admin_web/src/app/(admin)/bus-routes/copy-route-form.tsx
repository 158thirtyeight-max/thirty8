"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui";
import { copyRoute } from "./actions";

/** Copy this bus's route onto another bus as an independent draft; confirms before replacing an existing route. */
export default function CopyRouteForm({ sourceBusId, targets }: { sourceBusId: string; targets: { id: string; label: string }[] }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [dest, setDest] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);

  function run(replace: boolean) {
    setError(null);
    start(async () => {
      const res = await copyRoute(sourceBusId, dest, replace);
      if (res.error) return setError(res.error);
      if (res.needsConfirmation) {
        const c = res.needsConfirmation;
        return setConfirm(
          `The destination bus already has ${c.hasRoute ? `a route${c.routeName ? ` (${c.routeName})` : ""}` : "an unsubmitted route draft"}. ` +
            `The copy becomes a new revision; the current route stays live until you publish it${c.hasDraft ? ", and the existing draft is discarded" : ""}.`,
        );
      }
      router.push(`/bus-routes/edit/${res.revisionId}`);
    });
  }

  return (
    <div className="space-y-3">
      <label className="block text-sm text-text-secondary">
        Copy to vehicle
        <select className="mt-1 block w-full max-w-sm rounded-md border border-border bg-background px-3 py-2 text-text-primary" value={dest} onChange={(e) => { setDest(e.target.value); setConfirm(null); }}>
          <option value="">Choose a bus…</option>
          {targets.map((t) => (
            <option key={t.id} value={t.id}>{t.label}</option>
          ))}
        </select>
      </label>
      <p className="text-xs text-text-tertiary">
        Stops, order, boarding/dropping, times, days and outbound/return settings are copied as independent data. Trips, bookings, passengers, seats, payments and approval history are not.
      </p>
      {confirm ? (
        <div className="max-w-xl rounded-md border border-warning/40 bg-warning/10 p-3 text-sm">
          <p className="mb-2">{confirm}</p>
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setConfirm(null)}>Cancel</Button>
            <Button disabled={pending} onClick={() => run(true)}>Replace via new revision</Button>
          </div>
        </div>
      ) : (
        <Button disabled={!dest || pending} onClick={() => run(false)}>Copy route</Button>
      )}
      {error && <p className="text-sm text-error">{error}</p>}
    </div>
  );
}
