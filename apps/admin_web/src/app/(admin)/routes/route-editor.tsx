"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui";
import { deleteRoute, saveRoute, type RouteStopInput } from "./actions";

/* eslint-disable @typescript-eslint/no-explicit-any */

const inputClass = "w-full rounded-md border border-border bg-background px-2 py-1 text-sm text-text-primary";

type City = { id: string; name: string; location_code?: string };
type Stop = { name: string; city_id: string; is_boarding: boolean; is_dropping: boolean; arrival: string; departure: string };

const blankStop = (over: Partial<Stop> = {}): Stop => ({ name: "", city_id: "", is_boarding: true, is_dropping: true, arrival: "", departure: "", ...over });
const num = (v: string) => (v.trim() === "" ? null : Number(v));

export default function RouteEditor({ cities, mains, route }: { cities: City[]; mains: City[]; route: any | null }) {
  const router = useRouter();
  const [pending, start] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [name, setName] = useState<string>(route?.name ?? "");
  const [source, setSource] = useState<string>(route?.source_city_id ?? "");
  const [dest, setDest] = useState<string>(route?.destination_city_id ?? "");
  const [duration, setDuration] = useState<string>(route?.est_duration_min?.toString() ?? "");
  const [active, setActive] = useState<boolean>(route?.is_active ?? true);
  const [stops, setStops] = useState<Stop[]>(
    route
      ? route.stops.map((s: any) => ({
          name: s.name,
          city_id: s.city_id ?? "",
          is_boarding: s.is_boarding,
          is_dropping: s.is_dropping,
          arrival: s.arrival_offset_min?.toString() ?? "",
          departure: s.departure_offset_min?.toString() ?? "",
        }))
      : [blankStop({ is_dropping: false, arrival: "0", departure: "0" }), blankStop({ is_boarding: false })],
  );

  const update = (i: number, patch: Partial<Stop>) => setStops((s) => s.map((x, j) => (j === i ? { ...x, ...patch } : x)));
  const move = (i: number, d: number) =>
    setStops((s) => {
      const j = i + d;
      if (j < 0 || j >= s.length) return s;
      const c = [...s];
      [c[i], c[j]] = [c[j], c[i]];
      return c;
    });

  function pickCity(which: "source" | "dest", id: string) {
    const cityName = cities.find((c) => c.id === id)?.name ?? "";
    if (which === "source") {
      setSource(id);
      setStops((s) => s.map((x, i) => (i === 0 ? { ...x, city_id: id, name: x.name || cityName } : x)));
    } else {
      setDest(id);
      setStops((s) => s.map((x, i) => (i === s.length - 1 ? { ...x, city_id: id, name: x.name || cityName } : x)));
    }
  }

  function submit() {
    setError(null);
    const payloadStops: RouteStopInput[] = stops.map((s, i) => ({
      name: s.name,
      city_id: s.city_id || null,
      is_boarding: i === 0 ? true : s.is_boarding,
      is_dropping: i === stops.length - 1 ? true : s.is_dropping,
      arrival_offset_min: i === 0 ? 0 : num(s.arrival),
      departure_offset_min: i === stops.length - 1 ? num(s.arrival) : num(s.departure),
    }));
    start(async () => {
      const res = await saveRoute({
        id: route?.id ?? null,
        name,
        source_city_id: source,
        destination_city_id: dest,
        est_duration_min: num(duration),
        is_active: active,
        stops: payloadStops,
      });
      if (res.error) setError(res.error);
      else router.push("/routes");
    });
  }

  function remove() {
    if (!route || !confirm("Delete this route? Buses that already use it keep their own copy.")) return;
    start(async () => {
      const res = await deleteRoute(route.id);
      if (res.error) setError(res.error);
      else router.push("/routes");
    });
  }

  return (
    <div className="max-w-4xl space-y-6">
      {error && <p className="rounded-md border border-error/40 bg-error/10 px-4 py-3 text-sm text-error">{error}</p>}

      <div className="grid grid-cols-1 gap-3 rounded-lg border border-border bg-surface p-4 md:grid-cols-2">
        <label className="text-sm md:col-span-2">
          Route name
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Diglipur to Port Blair" className={inputClass} />
        </label>
        <label className="text-sm">
          Origin city
          <select value={source} onChange={(e) => pickCity("source", e.target.value)} className={inputClass}>
            <option value="">Select…</option>
            {mains.map((c) => (
              <option key={c.id} value={c.id}>{c.location_code ? `${c.name} (${c.location_code})` : c.name}</option>
            ))}
          </select>
        </label>
        <label className="text-sm">
          Destination city
          <select value={dest} onChange={(e) => pickCity("dest", e.target.value)} className={inputClass}>
            <option value="">Select…</option>
            {mains.map((c) => (
              <option key={c.id} value={c.id}>{c.location_code ? `${c.name} (${c.location_code})` : c.name}</option>
            ))}
          </select>
        </label>
        <label className="text-sm">
          Journey duration (minutes)
          <input type="number" min="1" value={duration} onChange={(e) => setDuration(e.target.value)} className={inputClass} />
        </label>
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={active} onChange={(e) => setActive(e.target.checked)} /> Active (visible to operators and customers)
        </label>
      </div>

      <section className="space-y-2">
        <h3 className="text-base font-semibold">Stops in travel order</h3>
        {stops.map((s, i) => {
          const first = i === 0;
          const last = i === stops.length - 1;
          return (
            <div key={i} className="grid grid-cols-1 items-end gap-3 rounded-lg border border-border bg-surface p-3 md:grid-cols-12">
              <div className="text-xs text-text-tertiary md:col-span-12">{first ? "Origin" : last ? "Destination" : `Stop ${i}`}</div>
              <label className="text-xs md:col-span-3">
                Stop name
                <input value={s.name} onChange={(e) => update(i, { name: e.target.value })} className={inputClass} />
              </label>
              <label className="text-xs md:col-span-3">
                Location
                <select value={s.city_id} onChange={(e) => update(i, { city_id: e.target.value })} className={inputClass}>
                  <option value="">Select…</option>
                  {cities.map((c) => (
                    <option key={c.id} value={c.id}>{c.location_code ? `${c.name} (${c.location_code})` : c.name}</option>
                  ))}
                </select>
              </label>
              <label className="text-xs md:col-span-1">
                Arrive (min)
                <input type="number" min="0" value={first ? "0" : s.arrival} disabled={first} onChange={(e) => update(i, { arrival: e.target.value })} className={inputClass} />
              </label>
              <label className="text-xs md:col-span-1">
                Depart (min)
                <input type="number" min="0" value={last ? s.arrival : s.departure} disabled={last} onChange={(e) => update(i, { departure: e.target.value })} className={inputClass} />
              </label>
              <div className="flex gap-3 text-xs md:col-span-2">
                <label className="flex items-center gap-1">
                  <input type="checkbox" checked={first || s.is_boarding} disabled={first} onChange={(e) => update(i, { is_boarding: e.target.checked })} /> Board
                </label>
                <label className="flex items-center gap-1">
                  <input type="checkbox" checked={last || s.is_dropping} disabled={last} onChange={(e) => update(i, { is_dropping: e.target.checked })} /> Drop
                </label>
              </div>
              <div className="flex gap-1 md:col-span-2">
                <Button type="button" variant="outline" onClick={() => move(i, -1)} disabled={first} aria-label="Move up">↑</Button>
                <Button type="button" variant="outline" onClick={() => move(i, 1)} disabled={last} aria-label="Move down">↓</Button>
                {!first && !last && (
                  <Button type="button" variant="outline" onClick={() => setStops((x) => x.filter((_, j) => j !== i))} aria-label="Remove stop">✕</Button>
                )}
              </div>
            </div>
          );
        })}
        <Button type="button" variant="ghost" onClick={() => setStops((s) => [...s.slice(0, -1), blankStop(), s[s.length - 1]])}>
          + Add intermediate stop
        </Button>
      </section>

      <div className="flex gap-3">
        <Button type="button" onClick={submit} disabled={pending}>{pending ? "Saving…" : "Save route"}</Button>
        <Button type="button" variant="outline" onClick={() => router.push("/routes")} disabled={pending}>Cancel</Button>
        {route && <Button type="button" variant="destructive" onClick={remove} disabled={pending}>Delete</Button>}
      </div>
    </div>
  );
}
