/* eslint-disable @typescript-eslint/no-explicit-any */

const DAY_NAMES = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

function clock(departureTime: string | null | undefined, offsetMin: number | null | undefined): string {
  if (offsetMin == null) return "—";
  if (!departureTime) return `+${offsetMin}m`;
  const [h, m] = departureTime.split(":").map(Number);
  const total = h * 60 + m + offsetMin;
  const dayShift = Math.floor(total / 1440);
  const t = ((total % 1440) + 1440) % 1440;
  const hh = String(Math.floor(t / 60)).padStart(2, "0");
  const mm = String(t % 60).padStart(2, "0");
  return `${hh}:${mm}${dayShift > 0 ? ` (+${dayShift}d)` : ""}`;
}

function days(list: number[] | null | undefined): string {
  if (!list || list.length === 0) return "—";
  if (list.length === 7) return "Every day";
  return [...list].sort().map((d) => DAY_NAMES[d]).join(", ");
}

/** Highlight for a stop row given the change set of its direction. */
function stopMark(cityId: string, changes: any, side: "current" | "proposed"): { label: string | null; cls: string } {
  if (!changes) return { label: null, cls: "" };
  const inList = (arr: any[] | undefined) => (arr ?? []).some((x) => x.city_id === cityId);
  if (side === "proposed" && inList(changes.added_stops)) return { label: "Added", cls: "bg-success/10" };
  if (side === "current" && inList(changes.removed_stops)) return { label: "Removed", cls: "bg-error/10" };
  const marks: string[] = [];
  if (inList(changes.resequenced)) marks.push("Moved");
  if (inList(changes.permission_changes)) marks.push("Boarding/drop changed");
  if (inList(changes.time_changes)) marks.push("Times changed");
  if (marks.length) return { label: marks.join(" · "), cls: "bg-warning/10" };
  return { label: null, cls: "" };
}

function Timeline({ journey, changes, side }: { journey: any; changes: any; side: "current" | "proposed" }) {
  if (!journey) return <p className="text-sm text-text-tertiary">{side === "current" ? "No journey is live in this direction." : "No journey proposed."}</p>;
  return (
    <div>
      <p className="mb-2 text-sm text-text-secondary">
        {journey.source_name} → {journey.destination_name}
        <span className="text-text-tertiary">
          {" "}
          · departs {journey.departure_time ? String(journey.departure_time).slice(0, 5) : "—"} · {journey.duration_min ? `${journey.duration_min} min` : "no duration"} ·{" "}
          {days(journey.operating_days)}
        </span>
      </p>
      <ol className="space-y-1">
        {(journey.stops ?? []).map((s: any, i: number, arr: any[]) => {
          const mark = stopMark(s.city_id, changes, side);
          const role = [s.is_boarding ? "Board" : null, s.is_dropping ? "Drop" : null].filter(Boolean).join(" + ");
          return (
            <li key={`${s.city_id}-${i}`} className={`rounded-md border border-divider px-3 py-2 text-sm ${mark.cls}`}>
              <div className="flex items-baseline justify-between gap-3">
                <span className="font-medium text-text-primary">
                  {i + 1}. {s.name}
                  {i === 0 && <span className="ml-2 text-xs text-text-tertiary">Start</span>}
                  {i === arr.length - 1 && <span className="ml-2 text-xs text-text-tertiary">Destination</span>}
                </span>
                {mark.label && <span className="text-xs font-medium text-text-secondary">{mark.label}</span>}
              </div>
              <div className="text-xs text-text-tertiary">
                {role || "—"} · arr {clock(journey.departure_time, s.arrival_offset_min)} · dep {clock(journey.departure_time, s.departure_offset_min)}
              </div>
            </li>
          );
        })}
      </ol>
    </div>
  );
}

function Summary({ changes }: { changes: any }) {
  if (!changes) return null;
  if (changes.added_journey) return <p className="mb-3 rounded-md bg-success/10 px-3 py-2 text-sm text-success">This journey is new.</p>;
  if (changes.removed_journey) return <p className="mb-3 rounded-md bg-error/10 px-3 py-2 text-sm text-error">This journey would be removed.</p>;
  const items: string[] = [];
  for (const s of changes.added_stops ?? []) items.push(`Added stop: ${s.name}`);
  for (const s of changes.removed_stops ?? []) items.push(`Removed stop: ${s.name}`);
  for (const s of changes.resequenced ?? []) items.push(`Order changed: ${s.name} (position ${s.from} → ${s.to})`);
  for (const s of changes.permission_changes ?? []) {
    const parts = [];
    if (s.boarding.from !== s.boarding.to) parts.push(`boarding ${s.boarding.from ? "on" : "off"} → ${s.boarding.to ? "on" : "off"}`);
    if (s.dropping.from !== s.dropping.to) parts.push(`dropping ${s.dropping.from ? "on" : "off"} → ${s.dropping.to ? "on" : "off"}`);
    items.push(`Permissions at ${s.name}: ${parts.join(", ")}`);
  }
  for (const s of changes.time_changes ?? []) {
    items.push(`Times at ${s.name}: arr ${s.arrival.from ?? "—"} → ${s.arrival.to ?? "—"} min, dep ${s.departure.from ?? "—"} → ${s.departure.to ?? "—"} min`);
  }
  if (changes.direction_changed) items.push("Route direction (start or destination) changed");
  for (const f of changes.schedule_changes ?? []) {
    items.push(`Schedule changed: ${String(f).replace(/_/g, " ")}`);
  }
  if (items.length === 0) return <p className="mb-3 text-sm text-text-tertiary">No differences in this direction.</p>;
  return (
    <ul className="mb-3 list-disc space-y-0.5 pl-5 text-sm text-text-primary">
      {items.map((t) => (
        <li key={t}>{t}</li>
      ))}
    </ul>
  );
}

export function DirectionCompare({ title, block }: { title: string; block: any }) {
  const hidden = !block?.current && !block?.proposed;
  if (hidden) return null;
  return (
    <section className="mb-8">
      <h3 className="mb-3 text-base font-semibold text-text-primary">{title}</h3>
      <Summary changes={block.changes} />
      <div className="grid gap-4 lg:grid-cols-2">
        <div>
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-text-tertiary">Current route</p>
          <Timeline journey={block.current} changes={block.changes} side="current" />
        </div>
        <div>
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-text-tertiary">Proposed route</p>
          <Timeline journey={block.proposed} changes={block.changes} side="proposed" />
        </div>
      </div>
    </section>
  );
}
