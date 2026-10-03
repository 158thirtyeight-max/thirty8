"use client";

import { useState, useTransition } from "react";
import { Button } from "@/components/ui";
import { decideCancellation, runGenerationNow } from "../actions";

export function DecisionButtons({ tripId }: { tripId: string }) {
  const [isPending, startTransition] = useTransition();
  const [note, setNote] = useState("");
  const [error, setError] = useState<string | null>(null);

  const decide = (approve: boolean) => {
    if (approve && !window.confirm("Approve? The departure is cancelled and all its bookings are cancelled with refunds queued.")) return;
    startTransition(async () => {
      setError(null);
      try {
        await decideCancellation(tripId, approve, note);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Failed");
      }
    });
  };

  return (
    <div className="flex flex-col gap-2">
      <input
        value={note}
        onChange={(e) => setNote(e.target.value)}
        placeholder="Note (optional)"
        className="rounded-md border border-border bg-background px-2 py-1 text-xs"
      />
      <div className="flex gap-2">
        <Button disabled={isPending} onClick={() => decide(true)} className="!px-3 !py-1.5 text-xs">
          Approve
        </Button>
        <Button variant="outline" disabled={isPending} onClick={() => decide(false)} className="!px-3 !py-1.5 text-xs">
          Reject
        </Button>
      </div>
      {error && <p className="max-w-xs text-xs text-error">{error}</p>}
    </div>
  );
}

export function RunNowButton() {
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <div>
      <Button
        variant="outline"
        disabled={isPending}
        onClick={() =>
          startTransition(async () => {
            setError(null);
            try {
              await runGenerationNow();
            } catch (e) {
              setError(e instanceof Error ? e.message : "Failed");
            }
          })
        }
      >
        {isPending ? "Running…" : "Run generator now"}
      </Button>
      {error && <p className="mt-1 text-xs text-error">{error}</p>}
    </div>
  );
}
