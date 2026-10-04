"use client";

import { useState, useTransition } from "react";
import { Button } from "@/components/ui";
import { saveGlobalSettings } from "../actions";

export type GlobalSettings = {
  timezone: string;
  default_advance_days: number;
  min_advance_days: number;
  max_advance_days: number;
  allow_operator_overrides: boolean;
  default_booking_close_minutes: number;
  max_booking_close_minutes: number;
  default_boarding_cutoff_minutes: number;
  max_boarding_cutoff_minutes: number;
  allow_operator_booking_rules: boolean;
  updated_at: string;
};

function NumberField({ name, label, value, hint }: { name: string; label: string; value: number; hint?: string }) {
  return (
    <label className="flex flex-col gap-1 text-sm">
      <span className="font-medium text-text-primary">{label}</span>
      <input
        type="number"
        min={0}
        name={name}
        defaultValue={value}
        required
        className="rounded-md border border-border bg-background px-3 py-2 text-text-primary"
      />
      {hint && <span className="text-xs text-text-tertiary">{hint}</span>}
    </label>
  );
}

export default function GlobalSettingsForm({ settings }: { settings: GlobalSettings }) {
  const [isPending, startTransition] = useTransition();
  const [message, setMessage] = useState<{ ok: boolean; text: string } | null>(null);

  return (
    <form
      action={(formData) =>
        startTransition(async () => {
          setMessage(null);
          try {
            await saveGlobalSettings(formData);
            setMessage({ ok: true, text: "Saved. Departures for the new window are generated automatically." });
          } catch (e) {
            setMessage({ ok: false, text: e instanceof Error ? e.message : "Could not save" });
          }
        })
      }
      className="rounded-lg border border-border bg-surface p-5"
    >
      <div className="grid gap-4 sm:grid-cols-3">
        <NumberField name="default_advance_days" label="Global default (days)" value={settings.default_advance_days} hint="Used by every route without its own override" />
        <NumberField name="min_advance_days" label="Minimum (days)" value={settings.min_advance_days} />
        <NumberField name="max_advance_days" label="Maximum (days)" value={settings.max_advance_days} />
        <NumberField name="default_booking_close_minutes" label="Booking closes (min before departure)" value={settings.default_booking_close_minutes} />
        <NumberField name="max_booking_close_minutes" label="Operator max: booking close (min)" value={settings.max_booking_close_minutes} />
        <div />
        <NumberField name="default_boarding_cutoff_minutes" label="Boarding cut-off (min before departure)" value={settings.default_boarding_cutoff_minutes} />
        <NumberField name="max_boarding_cutoff_minutes" label="Operator max: boarding cut-off (min)" value={settings.max_boarding_cutoff_minutes} />
      </div>

      <div className="mt-4 flex flex-col gap-2 text-sm text-text-primary">
        <label className="flex items-center gap-2">
          <input type="checkbox" name="allow_operator_overrides" defaultChecked={settings.allow_operator_overrides} />
          Allow admin-approved operator-specific windows (applies only to approved operators, below route overrides)
        </label>
        <label className="flex items-center gap-2">
          <input type="checkbox" name="allow_operator_booking_rules" defaultChecked={settings.allow_operator_booking_rules} />
          Let operators set booking-close and boarding cut-off within the maximums above
        </label>
      </div>

      <div className="mt-5 flex items-center gap-4">
        <Button type="submit" disabled={isPending}>
          {isPending ? "Saving…" : "Save global settings"}
        </Button>
        <span className="text-xs text-text-tertiary">
          Timezone: {settings.timezone} · Last updated {new Date(settings.updated_at).toLocaleString()}
        </span>
      </div>
      {message && <p className={`mt-3 text-sm ${message.ok ? "text-success" : "text-error"}`}>{message.text}</p>}
    </form>
  );
}
