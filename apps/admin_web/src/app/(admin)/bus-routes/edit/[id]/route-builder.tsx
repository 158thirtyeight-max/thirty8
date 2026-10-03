"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Badge, Button } from "@/components/ui";
import TimeRuler from "@/components/time-ruler";
import { DirectionCompare } from "../../../route-approvals/route-compare";
import { discardDraft, generateReverse, getDiff, publishRevision, saveRevision } from "../../actions";
import {
  DAY_LABELS,
  DWELL_CHOICES,
  MAX_DWELL,
  SNAP_MINUTES,
  arrivalBounds,
  autoSchedule,
  blankJourney,
  blankStop,
  describeDays,
  endClock,
  formatDuration,
  hasWindow,
  scheduleConflicts,
  setEnd,
  setStart,
  stateConflicts,
  stateFromRevision,
  statePayload,
  timeLabel,
  toClock,
  toMinutes,
  validateState,
  type BuilderJourney,
  type BuilderState,
} from "@/lib/route-builder";

/* eslint-disable @typescript-eslint/no-explicit-any */

type Loc = { id: string; name: string; location_code?: string; is_pickup_enabled?: boolean; is_drop_enabled?: boolean };

const input = "w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-text-primary";

function Segmented<T extends string | number>({ value, options, onChange, disabled }: { value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; disabled?: boolean }) {
  return (
    <div className="inline-flex overflow-hidden rounded-md border border-border">
      {options.map((o) => (
        <button
          key={String(o.value)}
          type="button"
          disabled={disabled}
          onClick={() => onChange(o.value)}
          className={`px-4 py-2 text-sm transition disabled:opacity-50 ${value === o.value ? "bg-primary text-white" : "bg-surface text-text-secondary hover:text-primary"}`}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

function DaysPicker({ days, onChange, disabled }: { days: number[]; onChange: (d: number[]) => void; disabled?: boolean }) {
  return (
    <div className="flex flex-wrap gap-2">
      {[1, 2, 3, 4, 5, 6, 7].map((d) => {
        const on = days.includes(d);
        return (
          <button
            key={d}
            type="button"
            disabled={disabled}
            onClick={() => onChange(on ? days.filter((x) => x !== d) : [...days, d])}
            className={`rounded-pill border px-3 py-1 text-sm transition disabled:opacity-50 ${on ? "border-primary bg-primary/10 text-primary" : "border-border text-text-secondary"}`}
          >
            {DAY_LABELS[d]}
          </button>
        );
      })}
    </div>
  );
}

/** Starting point, destination, departure / arrival time and operating days of one journey. */
function JourneySetup({ j, mains, locations, onChange, disabled }: { j: BuilderJourney; mains: Loc[]; locations: Loc[]; onChange: (j: BuilderJourney) => void; disabled?: boolean }) {
  const nameOf = (id: string) => locations.find((l) => l.id === id)?.name ?? "";
  function setCity(which: "source" | "dest", id: string) {
    const stops = j.stops.map((s, i) => ((which === "source" && i === 0) || (which === "dest" && i === j.stops.length - 1) ? { ...s, city_id: id, name: nameOf(id) } : s));
    onChange(autoSchedule({ ...j, ...(which === "source" ? { source_city_id: id } : { destination_city_id: id }), stops }));
  }
  const end = endClock(j);
  const nextDays = j.start != null && j.duration != null ? Math.floor((j.start + j.duration) / 1440) : 0;
  return (
    <div className="grid gap-4 md:grid-cols-2">
      <label className="text-sm text-text-secondary">
        Starting point
        <select disabled={disabled} className={`${input} mt-1`} value={j.source_city_id} onChange={(e) => setCity("source", e.target.value)}>
          <option value="">Choose…</option>
          {mains.map((c) => (
            <option key={c.id} value={c.id}>{c.name}</option>
          ))}
        </select>
      </label>
      <label className="text-sm text-text-secondary">
        Destination
        <select disabled={disabled} className={`${input} mt-1`} value={j.destination_city_id} onChange={(e) => setCity("dest", e.target.value)}>
          <option value="">Choose…</option>
          {mains.map((c) => (
            <option key={c.id} value={c.id}>{c.name}</option>
          ))}
        </select>
      </label>
      <label className="text-sm text-text-secondary">
        Departure time
        <input type="time" disabled={disabled} className={`${input} mt-1`} value={toClock(j.start)} onChange={(e) => { const m = toMinutes(e.target.value); if (m != null) onChange(setStart(j, m)); }} />
      </label>
      <label className="text-sm text-text-secondary">
        Arrival time {nextDays > 0 && <span className="text-text-tertiary">(+{nextDays} day{nextDays > 1 ? "s" : ""})</span>}
        <input type="time" disabled={disabled || j.start == null} className={`${input} mt-1`} value={toClock(end)} onChange={(e) => { const m = toMinutes(e.target.value); if (m != null) onChange(setEnd(j, m)); }} />
        {j.start == null && <span className="text-xs text-text-tertiary">Set the departure time first.</span>}
      </label>
      <div className="md:col-span-2">
        <p className="mb-1 text-sm text-text-secondary">Operating days</p>
        <DaysPicker days={j.operating_days} disabled={disabled} onChange={(d) => onChange({ ...j, operating_days: d })} />
      </div>
    </div>
  );
}

/** Stop editor (bottom sheet on phones): location, boarding / dropping, then the time ruler and stop time. */
function StopSheet({ j, index, locations, disabled, onChange, onRemove, onClose }: { j: BuilderJourney; index: number; locations: Loc[]; disabled?: boolean; onChange: (j: BuilderJourney) => void; onRemove: () => void; onClose: () => void }) {
  const s = j.stops[index];
  const first = index === 0;
  const lastStop = index === j.stops.length - 1;
  const inter = !first && !lastStop;
  const taken = new Set(j.stops.filter((_, i) => i !== index).map((x) => x.city_id));
  const options = locations.filter((l) => l.id === s.city_id || (!taken.has(l.id) && (!s.is_boarding || l.is_pickup_enabled !== false) && (!s.is_dropping || l.is_drop_enabled !== false)));
  const patch = (p: Partial<typeof s>) => onChange(autoSchedule({ ...j, stops: j.stops.map((x, i) => (i === index ? { ...x, ...p } : x)) }));

  const bounds = inter ? arrivalBounds(j, index) : null;
  const arrival = bounds ? Math.min(Math.max(s.arrival_offset ?? bounds.min, bounds.min), bounds.max) : 0;
  const customDwell = !DWELL_CHOICES.includes(s.dwell);
  const setArrival = (v: number) => bounds && patch({ arrival_offset: Math.min(Math.max(v, bounds.min), bounds.max), manual: true });
  const setDwell = (d: number) => patch({ dwell: Math.min(Math.max(d, 1), MAX_DWELL) });

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 md:items-center" onClick={onClose}>
      <div className="max-h-[92vh] w-full max-w-md overflow-y-auto rounded-t-xl bg-surface p-5 shadow-xl md:rounded-xl" onClick={(e) => e.stopPropagation()}>
        <h4 className="mb-3 text-base font-semibold">{first ? "Starting point" : lastStop ? "Destination" : `Stop ${index}`}</h4>
        <div className="space-y-3">
          <label className="block text-sm text-text-secondary">
            Location
            <select
              disabled={disabled || first || lastStop}
              className={`${input} mt-1`}
              value={s.city_id}
              onChange={(e) => patch({ city_id: e.target.value, name: locations.find((l) => l.id === e.target.value)?.name ?? "" })}
            >
              <option value="">Choose…</option>
              {options.map((l) => (
                <option key={l.id} value={l.id}>{l.name}{l.location_code ? ` · ${l.location_code}` : ""}</option>
              ))}
            </select>
          </label>
          <div className="flex gap-4 text-sm">
            <label className="flex items-center gap-2">
              <input type="checkbox" disabled={disabled || first} checked={s.is_boarding} onChange={(e) => patch({ is_boarding: e.target.checked })} /> Boarding
            </label>
            <label className="flex items-center gap-2">
              <input type="checkbox" disabled={disabled || lastStop} checked={s.is_dropping} onChange={(e) => patch({ is_dropping: e.target.checked })} /> Dropping
            </label>
          </div>

          {!inter && (
            <p className="text-sm text-text-secondary">
              {first
                ? `Departs ${j.start == null ? "— set the departure time in step 1" : toClock(j.start)}`
                : `Arrives ${j.start == null || j.duration == null ? "— set the arrival time in step 1" : timeLabel(j, j.duration)}`}
            </p>
          )}

          {inter && !bounds && <p className="text-sm text-text-secondary">Set the departure time and the destination arrival time first, then schedule this stop.</p>}

          {inter && bounds && (
            <div className="space-y-3">
              <div className="text-center">
                <p className="text-xs uppercase tracking-wide text-text-tertiary">Bus arrives</p>
                <p className="text-4xl font-bold text-primary">{timeLabel(j, arrival)}</p>
              </div>
              <TimeRuler start={j.start!} duration={j.duration!} value={arrival} min={bounds.min} max={bounds.max} disabled={disabled} onChange={setArrival} />
              <div className="flex items-center justify-center gap-3 text-sm text-text-secondary">
                <button type="button" aria-label="5 minutes earlier" disabled={disabled || arrival - SNAP_MINUTES < bounds.min} onClick={() => setArrival(arrival - SNAP_MINUTES)} className="h-10 w-10 rounded-full border border-border text-lg disabled:opacity-30">−</button>
                <span>fine adjust · {SNAP_MINUTES} min</span>
                <button type="button" aria-label="5 minutes later" disabled={disabled || arrival + SNAP_MINUTES > bounds.max} onClick={() => setArrival(arrival + SNAP_MINUTES)} className="h-10 w-10 rounded-full border border-border text-lg disabled:opacity-30">+</button>
              </div>
              <p className="text-center text-xs text-text-tertiary">This stop can be placed between {timeLabel(j, bounds.min)} and {timeLabel(j, bounds.max)}.</p>

              <div>
                <p className="mb-2 text-sm font-medium">How long will the bus stop here?</p>
                <div className="flex flex-wrap gap-2">
                  {DWELL_CHOICES.map((d) => (
                    <button key={d} type="button" disabled={disabled} onClick={() => setDwell(d)} className={`rounded-pill border px-3 py-1 text-sm ${s.dwell === d ? "border-primary bg-primary/10 text-primary" : "border-border text-text-secondary"}`}>{d} min</button>
                  ))}
                  <button type="button" disabled={disabled} onClick={() => setDwell(customDwell ? s.dwell : 20)} className={`rounded-pill border px-3 py-1 text-sm ${customDwell ? "border-primary bg-primary/10 text-primary" : "border-border text-text-secondary"}`}>Custom</button>
                </div>
                {customDwell && (
                  <div className="mt-2 flex items-center justify-center gap-3">
                    <button type="button" disabled={disabled || s.dwell <= 1} onClick={() => setDwell(s.dwell - 1)} className="h-9 w-9 rounded-full border border-border">−</button>
                    <span className="text-sm font-medium">{s.dwell} minutes</span>
                    <button type="button" disabled={disabled || s.dwell >= MAX_DWELL} onClick={() => setDwell(s.dwell + 1)} className="h-9 w-9 rounded-full border border-border">+</button>
                  </div>
                )}
              </div>
              <p className="text-sm">Bus leaves at <b>{timeLabel(j, arrival + s.dwell)}</b> <span className="text-text-tertiary">(calculated)</span></p>
            </div>
          )}
        </div>
        <div className="mt-5 flex justify-between">
          {inter && !disabled ? <Button variant="destructive" onClick={onRemove}>Remove stop</Button> : <span />}
          <Button onClick={onClose}>Done</Button>
        </div>
      </div>
    </div>
  );
}

/** Compact vertical timeline: starting point and destination are filled markers, intermediate stops rings. */
function StopTimeline({ j, locations, disabled, onChange }: { j: BuilderJourney; locations: Loc[]; disabled?: boolean; onChange: (j: BuilderJourney) => void }) {
  const [editing, setEditing] = useState<number | null>(null);
  const n = j.stops.length;
  const conflicts = new Map(scheduleConflicts(j).map((c) => [c.index, c.message]));
  const set = (next: BuilderJourney) => onChange(autoSchedule(next));
  function move(i: number, d: number) {
    const k = i + d;
    if (k < 1 || k > n - 2) return;
    const stops = [...j.stops];
    [stops[i], stops[k]] = [stops[k], stops[i]];
    set({ ...j, stops });
  }
  function add() {
    const stops = [...j.stops];
    stops.splice(n - 1, 0, blankStop());
    set({ ...j, stops });
    setEditing(n - 1);
  }
  function detail(i: number) {
    if (i === 0) return j.start == null ? "Set the departure time" : `Departs ${toClock(j.start)}`;
    if (i === n - 1) return j.start == null || j.duration == null ? "Set the arrival time" : `Arrives ${timeLabel(j, j.duration)}`;
    const a = j.stops[i].arrival_offset;
    if (!hasWindow(j) || a == null) return "Time not scheduled yet";
    return `Arr ${timeLabel(j, a)} · stops ${j.stops[i].dwell} min · Dep ${timeLabel(j, a + j.stops[i].dwell)}`;
  }
  return (
    <div>
      <p className="mb-3 text-sm text-text-secondary">
        {hasWindow(j) ? "Add stops by location. Open a stop to set when the bus arrives and how long it stops." : "Set the departure and arrival times in step 1 to schedule the stops."}
      </p>
      {conflicts.size > 0 && (
        <div className="mb-3 rounded-md border border-error/40 bg-error/10 p-3 text-sm text-error">
          <p className="font-medium">These stops need a correction:</p>
          <ul className="list-disc pl-5">{[...conflicts.values()].map((m) => <li key={m}>{m}</li>)}</ul>
        </div>
      )}
      <ol>
        {j.stops.map((s, i) => {
          const end = i === 0 || i === n - 1;
          const bad = conflicts.has(i);
          return (
            <li key={i} className="flex gap-3">
              <div className="flex w-6 flex-col items-center">
                <div className={`w-0.5 flex-1 ${i === 0 ? "bg-transparent" : bad ? "bg-error/40" : "bg-primary/40"}`} />
                <div className={`rounded-full border-2 ${bad ? "border-error" : "border-primary"} ${end ? `h-4 w-4 ${bad ? "bg-error" : "bg-primary"}` : "h-3 w-3 bg-surface"}`} />
                <div className={`w-0.5 flex-1 ${i === n - 1 ? "bg-transparent" : bad ? "bg-error/40" : "bg-primary/40"}`} />
              </div>
              <div className="flex flex-1 items-center justify-between gap-3 py-2">
                <button type="button" onClick={() => setEditing(i)} className="flex-1 text-left">
                  <p className={end ? "font-semibold" : ""}>
                    {i + 1}. {s.name || <span className="text-text-tertiary">Choose a location</span>}
                    {i === 0 && <span className="ml-2 text-xs text-text-tertiary">Start</span>}
                    {i === n - 1 && <span className="ml-2 text-xs text-text-tertiary">Destination</span>}
                  </p>
                  <p className={`text-xs ${bad ? "text-error" : "text-text-secondary"}`}>{detail(i)}</p>
                  <p className="text-xs text-text-tertiary">{[s.is_boarding && "Boarding", s.is_dropping && "Dropping"].filter(Boolean).join(" · ") || "No boarding/dropping"}</p>
                </button>
                {!disabled && !end && (
                  <div className="flex gap-1">
                    <button type="button" aria-label="Move up" disabled={i <= 1} onClick={() => move(i, -1)} className="rounded border border-border px-2 text-sm disabled:opacity-30">↑</button>
                    <button type="button" aria-label="Move down" disabled={i >= n - 2} onClick={() => move(i, 1)} className="rounded border border-border px-2 text-sm disabled:opacity-30">↓</button>
                  </div>
                )}
                <button type="button" onClick={() => setEditing(i)} className="text-sm text-primary hover:underline">{disabled ? "View" : "Edit"}</button>
              </div>
            </li>
          );
        })}
      </ol>
      {!disabled && <Button variant="ghost" onClick={add}>+ Add stop</Button>}
      <p className="mt-2 text-xs text-text-tertiary">
        Journey time: {formatDuration(j.duration)} · Operating: {describeDays(j.operating_days)}
      </p>
      {editing != null && j.stops[editing] && (
        <StopSheet
          j={j}
          index={editing}
          locations={locations}
          disabled={disabled}
          onChange={onChange}
          onRemove={() => {
            set({ ...j, stops: j.stops.filter((_, i) => i !== editing) });
            setEditing(null);
          }}
          onClose={() => setEditing(null)}
        />
      )}
    </div>
  );
}

export default function RouteBuilder({ revision, bus, operatorName, locations, mains, previousRevisionNo }: { revision: any; bus: any; operatorName: string; locations: Loc[]; mains: Loc[]; previousRevisionNo: number | null }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [state, setState] = useState<BuilderState>(() => stateFromRevision(revision));
  const [step, setStep] = useState(0);
  const [dirty, setDirty] = useState(false);
  const [problems, setProblems] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [diff, setDiff] = useState<any>(null);
  const [publishing, setPublishing] = useState(false);
  const [reason, setReason] = useState("");

  const editable = revision.status === "draft" && !!revision.admin_authored;
  const round = state.trip_type === "round_trip";
  const lastStep = round ? 2 : 1;
  const stepLabels = ["Journey setup", "Route timeline", ...(round ? ["Return journey"] : [])];

  const change = (next: BuilderState) => {
    setState(next);
    setDirty(true);
    setProblems([]);
    setError(null);
    setNotice(null);
    setDiff(null);
  };

  function setType(t: "one_way" | "round_trip") {
    if (t === "one_way") return change({ ...state, trip_type: "one_way" });
    const o = state.outbound;
    change({
      ...state,
      trip_type: "round_trip",
      return: state.return ?? {
        ...blankJourney(),
        source_city_id: o.destination_city_id,
        destination_city_id: o.source_city_id,
        stops: [blankStop({ city_id: o.destination_city_id, name: o.stops[o.stops.length - 1]?.name ?? "", is_dropping: false }), blankStop({ city_id: o.source_city_id, name: o.stops[0]?.name ?? "", is_boarding: false })],
      },
    });
  }

  function save(after?: () => void) {
    setError(null);
    const conflicts = stateConflicts(state);
    if (conflicts.length) {
      setProblems(conflicts);
      return setError("Fix the stop times shown in red before saving.");
    }
    start(async () => {
      const res = await saveRevision(revision.id, statePayload(state));
      if (res.error) return setError(res.error);
      setDirty(false);
      setProblems((res.validation?.errors ?? []).map((e) => `${e.direction === "return" ? "Return" : "Outbound"}: ${e.message}`));
      setNotice("Draft saved. The live route is unchanged.");
      after?.();
    });
  }

  function reverse() {
    const o = state.outbound;
    if (!hasWindow(o)) return setError("Set the outbound departure and arrival times first.");
    setError(null);
    const prev = state.return;
    start(async () => {
      const saved = await saveRevision(revision.id, statePayload(state));
      if (saved.error) return setError(saved.error);
      const res = await generateReverse(revision.id);
      if (res.error || !res.revision) return setError(res.error ?? "Could not generate the reverse route.");
      const next = stateFromRevision(res.revision);
      // the reverse route never copies outbound clock times: keep the return's own window, if it had one
      if (next.return && prev && hasWindow(prev)) {
        next.return = autoSchedule({ ...next.return, start: prev.start, duration: prev.duration });
        setDirty(true);
      } else {
        setDirty(false);
      }
      setState(next);
      setNotice(next.return && hasWindow(next.return) ? "Reverse route generated. It is an ordinary return journey: edit it freely." : "Reverse route created. Now set the return departure and arrival times.");
    });
  }

  function preview() {
    setError(null);
    const conflicts = stateConflicts(state);
    if (conflicts.length) {
      setProblems(conflicts);
      return setError("Fix the stop times shown in red before previewing.");
    }
    start(async () => {
      const saved = await saveRevision(revision.id, statePayload(state));
      if (saved.error) return setError(saved.error);
      setDirty(false);
      const res = await getDiff(revision.id);
      if (res.error) return setError(res.error);
      setDiff(res.diff);
    });
  }

  function openPublish() {
    const local = validateState(state);
    if (local.length) return setProblems(local);
    setPublishing(true);
  }

  function publish() {
    if (!reason.trim()) return setError("A reason for the change is required.");
    setError(null);
    start(async () => {
      const saved = await saveRevision(revision.id, statePayload(state));
      if (saved.error) return setError(saved.error);
      const res = await publishRevision(revision.id, reason.trim());
      if (res.error) return setError(res.error);
      if (!res.ok) {
        setPublishing(false);
        return setProblems((res.errors ?? []).map((e) => e.message));
      }
      router.push(`/bus-routes/${bus.id}?notice=published`);
    });
  }

  return (
    <div className="max-w-3xl">
      <div className="mb-4 rounded-lg border border-border bg-surface p-4 text-sm text-text-secondary">
        Editing revision {revision.revision_no} for <b>{bus.registration_number}</b> ({operatorName}).{" "}
        {revision.origin === "route_copy" ? "This draft was copied from another bus. " : ""}
        {previousRevisionNo != null ? `It starts from revision ${previousRevisionNo}, which stays live until you publish. ` : "This bus has no live route yet. "}
        <Badge status={revision.status} />
        {revision.status === "draft" && !revision.admin_authored && <p className="mt-2 text-warning">This is the operator&apos;s own draft: it is read only here. Only the operator can edit and submit it; you can discard it.</p>}
      </div>

      <div className="mb-6 flex items-center gap-2">
        {stepLabels.map((l, i) => (
          <button key={l} type="button" onClick={() => setStep(i)} className="flex items-center gap-2">
            {i > 0 && <span className="h-px w-8 bg-border" />}
            <span className={`flex h-6 w-6 items-center justify-center rounded-full text-xs ${i === step ? "bg-primary text-white" : "bg-surface text-text-secondary ring-1 ring-border"}`}>{i + 1}</span>
            <span className={`text-sm ${i === step ? "font-semibold" : "text-text-secondary"}`}>{l}</span>
          </button>
        ))}
      </div>

      {step === 0 && (
        <section className="space-y-4">
          <div>
            <p className="mb-1 text-sm text-text-secondary">Journey type</p>
            <Segmented value={state.trip_type} disabled={!editable} onChange={setType} options={[{ value: "one_way", label: "One way" }, { value: "round_trip", label: "Round trip" }]} />
          </div>
          <label className="block text-sm text-text-secondary">
            Route name
            <input disabled={!editable} className={`${input} mt-1`} value={state.name} onChange={(e) => change({ ...state, name: e.target.value })} placeholder="e.g. Mayabunder to Sri Vijaya Puram" />
          </label>
          <JourneySetup j={state.outbound} mains={mains} locations={locations} disabled={!editable} onChange={(j) => change({ ...state, outbound: j })} />
          {round && <p className="text-xs text-text-tertiary">The return journey has its own schedule: set it in the Return journey step.</p>}
        </section>
      )}

      {step === 1 && <StopTimeline j={state.outbound} locations={locations} disabled={!editable} onChange={(j) => change({ ...state, outbound: j })} />}

      {step === 2 && state.return && (
        <section className="space-y-4">
          <p className="text-sm text-text-secondary">The return is its own journey: its own stops, departure time and operating days. It may leave the same day or later.</p>
          {editable && <Button variant="outline" disabled={pending} onClick={reverse}>Generate reverse route</Button>}
          <div>
            <p className="mb-1 text-sm text-text-secondary">Return departs</p>
            <Segmented
              value={Math.min(state.return.departure_day_offset, 2)}
              disabled={!editable}
              onChange={(v) => {
                const r = state.return!;
                const by = v - r.departure_day_offset;
                change({ ...state, return: { ...r, departure_day_offset: v, operating_days: r.operating_days.map((d) => ((d - 1 + by + 7) % 7) + 1) } });
              }}
              options={[{ value: 0, label: "Same day" }, { value: 1, label: "Next day" }, { value: 2, label: "+2 days" }]}
            />
          </div>
          <JourneySetup j={state.return} mains={mains} locations={locations} disabled={!editable} onChange={(j) => change({ ...state, return: j })} />
          <StopTimeline j={state.return} locations={locations} disabled={!editable} onChange={(j) => change({ ...state, return: j })} />
        </section>
      )}

      {problems.length > 0 && (
        <ul className="mt-6 space-y-1 rounded-md border border-error/40 bg-error/10 p-3 text-sm text-error">
          {problems.map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      )}
      {error && <p className="mt-4 text-sm text-error">{error}</p>}
      {notice && <p className="mt-4 text-sm text-success">{notice}</p>}

      <div className="mt-6 flex flex-wrap items-center gap-3">
        {step > 0 && <Button variant="outline" onClick={() => setStep(step - 1)}>Back</Button>}
        {step < lastStep && <Button onClick={() => setStep(step + 1)}>Next</Button>}
        {editable && (
          <>
            <Button variant="outline" disabled={pending || !dirty} onClick={() => save()}>Save draft</Button>
            <Button variant="outline" disabled={pending} onClick={preview}>Preview changes</Button>
            {step === lastStep && <Button disabled={pending} onClick={openPublish}>Publish changes</Button>}
          </>
        )}
        {revision.status === "draft" && (
          <form action={discardDraft.bind(null, revision.id, bus.id)} className="ml-auto">
            <Button type="submit" variant="ghost" onClick={(e) => { if (!window.confirm("Discard this draft? The live route is not affected.")) e.preventDefault(); }}>Discard draft</Button>
          </form>
        )}
      </div>

      {diff && (
        <section className="mt-8">
          <h3 className="mb-3 text-lg font-semibold">Before and after</h3>
          <p className="mb-4 text-sm text-text-secondary">
            Trip type: {String(diff.trip_type?.current).replace(/_/g, " ")} → {String(diff.trip_type?.proposed).replace(/_/g, " ")}
          </p>
          <DirectionCompare title="Outbound journey" block={diff.outbound} />
          <DirectionCompare title="Return journey" block={diff.return} />
        </section>
      )}

      {publishing && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40" onClick={() => setPublishing(false)}>
          <div className="w-full max-w-md rounded-xl bg-surface p-5 shadow-xl" onClick={(e) => e.stopPropagation()}>
            <h4 className="mb-2 text-base font-semibold">Publish this route?</h4>
            <p className="mb-3 text-sm text-text-secondary">
              It becomes the live route for customer search immediately; the previous revision stays in the history. Existing bookings are not changed (affected ones are flagged). This is recorded under your account.
            </p>
            <textarea className={input} rows={3} placeholder="Reason for the change (required)" value={reason} onChange={(e) => setReason(e.target.value)} />
            {error && <p className="mt-2 text-sm text-error">{error}</p>}
            <div className="mt-4 flex justify-end gap-2">
              <Button variant="outline" onClick={() => setPublishing(false)}>Cancel</Button>
              <Button disabled={pending} onClick={publish}>Publish</Button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
