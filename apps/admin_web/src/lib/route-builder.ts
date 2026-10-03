/**
 * Route builder model shared by the admin route builder screens. Mirrors the operator app's
 * `route_model.dart` + `stop_schedule.dart` so both apps schedule stops the same way.
 *
 * A journey has a start (departure clock time at the origin) and a duration (arrival at the destination
 * = start + duration). Each intermediate stop has an arrival *offset* (minutes after the journey starts,
 * so overnight journeys stay chronological) and a dwell time; its departure is always arrival + dwell.
 * Offsets are what the database stores in arrival_offset_min / departure_offset_min, and the database
 * (`validate_route_revision`) validates the chronology independently. This client check is only the
 * quick feedback shown while editing.
 */

export const MINUTES_PER_DAY = 1440;
export const SNAP_MINUTES = 5;
export const DWELL_CHOICES = [2, 5, 10, 15];
export const DEFAULT_DWELL = 5;
export const MAX_DWELL = 360;
export const DAY_LABELS = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

export type BuilderStop = {
  city_id: string;
  name: string;
  is_boarding: boolean;
  is_dropping: boolean;
  /** Minutes after the journey starts at which the bus arrives (intermediate stops). */
  arrival_offset: number | null;
  /** How long the bus stops (minutes). */
  dwell: number;
  /** true = the user chose the time; false = an automatic estimate. */
  manual: boolean;
};

export type BuilderJourney = {
  source_city_id: string;
  destination_city_id: string;
  operating_days: number[];
  /** 0 = same day as the outbound, 1 = next day, ... (return journeys). */
  departure_day_offset: number;
  reverse_generated: boolean;
  /** Departure clock time at the starting point, minutes since midnight (null = not set). */
  start: number | null;
  /** Minutes from the departure to the destination arrival (null = not set). */
  duration: number | null;
  stops: BuilderStop[];
};

export type BuilderState = {
  trip_type: "one_way" | "round_trip";
  name: string;
  outbound: BuilderJourney;
  return: BuilderJourney | null;
};

export const blankStop = (over: Partial<BuilderStop> = {}): BuilderStop => ({
  city_id: "",
  name: "",
  is_boarding: true,
  is_dropping: true,
  arrival_offset: null,
  dwell: DEFAULT_DWELL,
  manual: false,
  ...over,
});

export const blankJourney = (): BuilderJourney => ({
  source_city_id: "",
  destination_city_id: "",
  operating_days: [1, 2, 3, 4, 5, 6, 7],
  departure_day_offset: 0,
  reverse_generated: false,
  start: null,
  duration: null,
  stops: [blankStop({ is_dropping: false }), blankStop({ is_boarding: false })],
});

// ---- clock helpers ---------------------------------------------------------------------------

/** "HH:MM" -> minutes since midnight, or null. */
export function toMinutes(clock: string): number | null {
  const m = /^(\d{1,2}):(\d{2})/.exec(clock ?? "");
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

export function toClock(minutes: number | null | undefined): string {
  if (minutes == null) return "";
  const t = ((minutes % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY;
  return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`;
}

export function formatDuration(minutes: number | null): string {
  if (minutes == null) return "—";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h === 0 ? `${m}m` : m === 0 ? `${h}h` : `${h}h ${m}m`;
}

export function describeDays(days: number[]): string {
  if (days.length === 7) return "Every day";
  if (days.length === 0) return "No days";
  return [...days].sort().map((d) => DAY_LABELS[d]).join(", ");
}

export const snapTo = (m: number, step = SNAP_MINUTES) => Math.round(m / step) * step;
const mod = (a: number, n: number) => ((a % n) + n) % n;

// ---- timeline scheduling ---------------------------------------------------------------------

const last = (j: BuilderJourney) => j.stops.length - 1;
const stopName = (j: BuilderJourney, i: number) => j.stops[i].name.trim() || `Stop ${i + 1}`;

export const hasWindow = (j: BuilderJourney) => j.start != null && j.duration != null && j.duration > 0;

/** Arrival clock time at the destination (minutes since midnight). */
export const endClock = (j: BuilderJourney) => (j.start == null || j.duration == null ? null : (j.start + j.duration) % MINUTES_PER_DAY);

/** "07:05", or "02:00 (+1 day)" past midnight. */
export function timeLabel(j: BuilderJourney, offset: number): string {
  const abs = (j.start ?? 0) + offset;
  const d = Math.floor(abs / MINUTES_PER_DAY);
  return `${toClock(abs)}${d > 0 ? ` (+${d} day${d > 1 ? "s" : ""})` : ""}`;
}

export function arrivalAt(j: BuilderJourney, i: number): number | null {
  if (i === 0) return 0;
  if (i === last(j)) return j.duration;
  return j.stops[i].arrival_offset;
}

export function departureAt(j: BuilderJourney, i: number): number | null {
  if (i === 0) return 0;
  if (i === last(j)) return j.duration;
  const a = j.stops[i].arrival_offset;
  return a == null ? null : a + j.stops[i].dwell;
}

/** The permitted arrival range (offsets) of intermediate stop i, or null when the window is not set. */
export function arrivalBounds(j: BuilderJourney, i: number): { min: number; max: number } | null {
  if (!hasWindow(j) || i <= 0 || i >= last(j)) return null;
  let lo = 0;
  for (let k = i - 1; k >= 0; k--) {
    const d = departureAt(j, k);
    if (d != null) { lo = d; break; }
  }
  let hi = j.duration! - j.stops[i].dwell;
  for (let k = i + 1; k <= last(j); k++) {
    const a = arrivalAt(j, k);
    if (a != null) { hi = a - j.stops[i].dwell; break; }
  }
  return { min: lo, max: Math.max(lo, hi) };
}

/**
 * Gives every stop without a manually chosen time an estimated arrival: evenly spread between the
 * surrounding fixed stops, snapped to 5 minutes. Manual times are never changed. Returns a new journey.
 */
export function autoSchedule(j: BuilderJourney): BuilderJourney {
  if (!hasWindow(j)) return j;
  const stops = j.stops.map((s) => ({ ...s }));
  const out: BuilderJourney = { ...j, stops };
  const isFixed = (s: BuilderStop) => s.manual && s.arrival_offset != null;
  let i = 1;
  while (i < last(out)) {
    if (isFixed(stops[i])) { i++; continue; }
    let k = i;
    while (k + 1 < last(out) && !isFixed(stops[k + 1])) k++;
    const prevEnd = departureAt(out, i - 1) ?? 0;
    const nextStart = arrivalAt(out, k + 1) ?? out.duration!;
    const run = stops.slice(i, k + 1);
    let remaining = run.reduce((a, s) => a + s.dwell, 0);
    const gap = Math.floor((nextStart - prevEnd - remaining) / (run.length + 1));
    let cursor = prevEnd;
    for (const s of run) {
      remaining -= s.dwell;
      let a = snapTo(cursor + Math.max(gap, 0));
      a = Math.min(a, nextStart - remaining - s.dwell);
      a = Math.max(a, cursor);
      s.arrival_offset = a;
      s.manual = false;
      cursor = a + s.dwell;
    }
    i = k + 1;
  }
  return out;
}

/** Sets the departure time at the origin. Manual stops keep their clock time (they are re-validated, not moved). */
export function setStart(j: BuilderJourney, clock: number): BuilderJourney {
  const old = j.start;
  if (old == null) return autoSchedule({ ...j, start: clock });
  if (old === clock) return j;
  const delta = clock - old;
  const oldEnd = j.duration == null ? null : (old + j.duration) % MINUTES_PER_DAY;
  const stops = j.stops.map((s, i) => (i > 0 && i < j.stops.length - 1 && s.manual && s.arrival_offset != null ? { ...s, arrival_offset: s.arrival_offset - delta } : s));
  let duration = j.duration;
  if (j.duration != null && oldEnd != null) {
    const extra = j.duration <= 0 ? 0 : Math.floor((j.duration - 1) / MINUTES_PER_DAY);
    let m = mod(oldEnd - clock, MINUTES_PER_DAY);
    if (m === 0) m = MINUTES_PER_DAY;
    duration = m + extra * MINUTES_PER_DAY;
  }
  return autoSchedule({ ...j, start: clock, duration, stops });
}

/** Sets the arrival time at the destination (journeys over 24 h keep their extra days). */
export function setEnd(j: BuilderJourney, clock: number): BuilderJourney {
  if (j.start == null) return j;
  const extra = j.duration == null || j.duration <= 0 ? 0 : Math.floor((j.duration - 1) / MINUTES_PER_DAY);
  let m = mod(clock - j.start, MINUTES_PER_DAY);
  if (m === 0) m = MINUTES_PER_DAY;
  return autoSchedule({ ...j, duration: m + extra * MINUTES_PER_DAY });
}

export type ScheduleConflict = { index: number; message: string };

/** Chronological problems, one per affected stop. */
export function scheduleConflicts(j: BuilderJourney): ScheduleConflict[] {
  const out: ScheduleConflict[] = [];
  if (!hasWindow(j)) return out;
  const dur = j.duration!;
  for (let i = 1; i < last(j); i++) {
    const s = j.stops[i];
    const a = s.arrival_offset;
    if (a == null) continue;
    const dep = a + s.dwell;
    let problem: string | null = null;
    if (s.dwell < 0 || s.dwell > MAX_DWELL) problem = "stop time must be between 0 and 6 hours";
    else if (a < 0) problem = `arrives before the journey starts (${timeLabel(j, 0)})`;
    else if (dep > dur) problem = `is still stopped after the destination arrival (${timeLabel(j, dur)})`;
    else {
      for (let k = i - 1; k >= 0; k--) {
        const d = departureAt(j, k);
        if (d != null) {
          if (a < d) problem = `arrives at ${timeLabel(j, a)}, before ${stopName(j, k)} is left at ${timeLabel(j, d)}`;
          break;
        }
      }
      if (!problem) {
        for (let k = i + 1; k <= last(j); k++) {
          const na = arrivalAt(j, k);
          if (na != null) {
            if (dep > na) problem = `leaves at ${timeLabel(j, dep)}, after ${stopName(j, k)} is reached at ${timeLabel(j, na)}`;
            break;
          }
        }
      }
    }
    if (problem) out.push({ index: i, message: `${stopName(j, i)} ${problem}` });
  }
  return out;
}

/** Everything wrong with one journey (locations, permissions, window, chronology). Empty = valid. */
export function validateJourney(j: BuilderJourney): string[] {
  const errors: string[] = [];
  const stops = j.stops;
  if (!j.source_city_id || !j.destination_city_id) errors.push("Choose a starting point and a destination");
  else if (j.source_city_id === j.destination_city_id) errors.push("Starting point and destination must be different");
  if (j.operating_days.length === 0) errors.push("Select at least one operating day");
  if (stops.length < 2) return [...errors, "A route needs at least a starting point and a destination"];
  if (stops.length > 30) errors.push("A route can have at most 30 stops");
  if (!stops[0].is_boarding) errors.push("The starting point must be a boarding point");
  if (!stops[stops.length - 1].is_dropping) errors.push("The destination must be a dropping point");
  stops.forEach((s, i) => {
    if (!s.city_id) errors.push(`${stopName(j, i)}: choose a location`);
    if (!s.is_boarding && !s.is_dropping) errors.push(`${stopName(j, i)}: choose boarding, dropping or both`);
  });
  if (stops.every((s) => s.city_id)) {
    if (j.source_city_id && stops[0].city_id !== j.source_city_id) errors.push("The first stop must be the starting point");
    if (j.destination_city_id && stops[stops.length - 1].city_id !== j.destination_city_id) errors.push("The last stop must be the destination");
    if (new Set(stops.map((s) => s.city_id)).size !== stops.length) errors.push("A location can appear only once on a route");
  }
  if (j.start == null) errors.push("Set the departure time at the starting point");
  if (j.duration == null || j.duration < 1) errors.push("Set the arrival time at the destination");
  else if (j.duration > 72 * 60) errors.push("Journey duration looks too long (over 72 hours)");
  if (hasWindow(j)) {
    stops.forEach((s, i) => {
      if (i > 0 && i < stops.length - 1 && s.arrival_offset == null) errors.push(`${stopName(j, i)}: choose an arrival time`);
    });
    errors.push(...scheduleConflicts(j).map((c) => c.message));
  }
  return errors;
}

export function validateState(s: BuilderState): string[] {
  const out = validateJourney(s.outbound).map((e) => `Outbound: ${e}`);
  if (s.trip_type === "round_trip") {
    if (!s.return) out.push("Return: configure the return journey");
    else {
      out.push(...validateJourney(s.return).map((e) => `Return: ${e}`));
      if (s.return.source_city_id !== s.outbound.destination_city_id || s.return.destination_city_id !== s.outbound.source_city_id)
        out.push("Return: it must start where the outbound ends and end where it starts");
    }
  }
  return out;
}

/** Schedule conflicts of both journeys, labelled; used to refuse saving an invalid timeline. */
export function stateConflicts(s: BuilderState): string[] {
  return [
    ...scheduleConflicts(s.outbound).map((c) => `Outbound: ${c.message}`),
    ...(s.trip_type === "round_trip" && s.return ? scheduleConflicts(s.return).map((c) => `Return: ${c.message}`) : []),
  ];
}

// ---- payload / persistence --------------------------------------------------------------------

/** Payload of one journey for save_route_revision. Stops without a location are left out of a draft. */
export function journeyPayload(j: BuilderJourney) {
  const n = j.stops.length;
  const arrival = (i: number) => (i === 0 ? 0 : i === n - 1 ? j.duration : j.stops[i].arrival_offset);
  const departure = (i: number) => {
    if (i === 0) return 0;
    if (i === n - 1) return j.duration;
    const a = j.stops[i].arrival_offset;
    return a == null ? null : a + j.stops[i].dwell;
  };
  return {
    source_city_id: j.source_city_id || null,
    destination_city_id: j.destination_city_id || null,
    departure_time: j.start == null ? null : `${toClock(j.start)}:00`,
    duration_min: j.duration,
    operating_days: [...j.operating_days].sort(),
    departure_day_offset: j.departure_day_offset,
    reverse_generated: j.reverse_generated,
    stops: j.stops
      .map((s, i) => ({ s, i }))
      .filter(({ s }) => s.city_id)
      .map(({ s, i }) => ({
        city_id: s.city_id,
        is_boarding: s.is_boarding,
        is_dropping: s.is_dropping,
        arrival_offset_min: arrival(i),
        departure_offset_min: departure(i),
      })),
  };
}

export function statePayload(s: BuilderState) {
  return {
    trip_type: s.trip_type,
    ...(s.name.trim() ? { name: s.name.trim() } : {}),
    outbound: journeyPayload(s.outbound),
    ...(s.trip_type === "round_trip" && s.return ? { return: journeyPayload(s.return) } : {}),
  };
}

/* eslint-disable @typescript-eslint/no-explicit-any */
/** Rebuilds one journey from a route_revision_journeys row with embedded route_revision_stops(location:locations(name)). */
export function journeyFromRow(row: any): BuilderJourney {
  const start = row.departure_time ? toMinutes(String(row.departure_time)) : null;
  const raw = [...(row.route_revision_stops ?? [])].sort((a: any, b: any) => a.sequence_no - b.sequence_no);
  const j: BuilderJourney = {
    source_city_id: row.source_city_id ?? "",
    destination_city_id: row.destination_city_id ?? "",
    operating_days: [...(row.operating_days ?? [])],
    departure_day_offset: row.departure_day_offset ?? 0,
    reverse_generated: !!row.reverse_generated,
    start,
    duration: row.est_duration_min ?? null,
    stops: raw.map((s: any) => {
      const a = s.arrival_offset_min ?? null;
      const d = s.departure_offset_min ?? null;
      return {
        city_id: s.city_id,
        name: s.location?.name ?? "",
        is_boarding: !!s.is_boarding,
        is_dropping: !!s.is_dropping,
        arrival_offset: a,
        dwell: a != null && d != null && d >= a ? d - a : DEFAULT_DWELL,
        // a journey with no departure yet (a fresh reverse route) keeps its stops as automatic estimates
        manual: start != null,
      };
    }),
  };
  // a draft may have been saved before every stop had a location: pad the two ends
  if (!j.stops.length || j.stops[0].city_id !== j.source_city_id) j.stops.unshift(blankStop({ city_id: j.source_city_id, is_dropping: false }));
  if (j.stops.length < 2 || j.stops[j.stops.length - 1].city_id !== j.destination_city_id) j.stops.push(blankStop({ city_id: j.destination_city_id, is_boarding: false }));
  return j;
}

export function stateFromRevision(rev: any): BuilderState {
  const journeys: any[] = rev.route_revision_journeys ?? [];
  const out = journeys.find((j) => j.direction === "outbound");
  const ret = journeys.find((j) => j.direction === "return");
  return {
    trip_type: rev.trip_type,
    name: rev.name ?? "",
    outbound: out ? journeyFromRow(out) : blankJourney(),
    return: ret ? journeyFromRow(ret) : null,
  };
}
