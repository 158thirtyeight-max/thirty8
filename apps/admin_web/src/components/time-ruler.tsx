"use client";

import { useEffect, useRef, useState } from "react";
import { MINUTES_PER_DAY, SNAP_MINUTES, snapTo, toClock } from "@/lib/route-builder";

const PAD = 18;

/**
 * Horizontal draggable time ruler for choosing when the bus reaches a stop. It always spans the whole
 * journey window (departure to destination arrival) so it fits any screen width, shows hour markers
 * with labels that adapt to the width, shades the range the stop may use and snaps to 5 minutes.
 * The value is an offset in minutes after the journey starts (overnight journeys stay chronological).
 * Also usable by keyboard (arrows ±5 min, Page Up/Down ±1 h) and exposes slider semantics.
 */
export default function TimeRuler({
  start,
  duration,
  value,
  min,
  max,
  onChange,
  disabled,
  snap = SNAP_MINUTES,
}: {
  start: number;
  duration: number;
  value: number;
  min: number;
  max: number;
  onChange: (offset: number) => void;
  disabled?: boolean;
  snap?: number;
}) {
  const box = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);
  const [width, setWidth] = useState(320);

  useEffect(() => {
    const el = box.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const ro = new ResizeObserver(([entry]) => setWidth(entry.contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const hi = Math.max(min, max);
  const clamp = (v: number) => Math.min(Math.max(v, min), hi);
  const pos = (offset: number) => `calc(${PAD}px + (100% - ${2 * PAD}px) * ${offset / duration})`;
  const label = (offset: number) => {
    const abs = start + offset;
    const d = Math.floor(abs / MINUTES_PER_DAY);
    return `${toClock(abs)}${d > 0 ? ` +${d}d` : ""}`;
  };

  function pick(clientX: number) {
    const el = box.current;
    if (!el || disabled) return;
    const r = el.getBoundingClientRect();
    const usable = r.width - 2 * PAD;
    const raw = Math.min(Math.max(((clientX - r.left - PAD) / usable) * duration, 0), duration);
    const next = clamp(snapTo(raw, snap));
    if (next !== value) onChange(next);
  }

  const pxPerHour = (width - 2 * PAD) / (duration / 60);
  const labelEvery = Math.max(1, Math.ceil(52 / Math.max(pxPerHour, 1)));
  const ticks: { offset: number; labelled: boolean; text: string }[] = [];
  const firstHour = Math.ceil(start / 60) * 60;
  for (let clock = firstHour, i = 0; clock - start <= duration; clock += 60, i++) {
    ticks.push({ offset: clock - start, labelled: i % labelEvery === 0, text: toClock(clock) });
  }

  return (
    <div
      ref={box}
      role="slider"
      tabIndex={disabled ? -1 : 0}
      aria-label="Arrival time"
      aria-valuemin={min}
      aria-valuemax={hi}
      aria-valuenow={value}
      aria-valuetext={label(value)}
      aria-disabled={disabled}
      className={`relative h-20 w-full touch-none select-none ${disabled ? "opacity-60" : "cursor-pointer"}`}
      onPointerDown={(e) => {
        if (disabled) return;
        dragging.current = true;
        e.currentTarget.setPointerCapture(e.pointerId);
        pick(e.clientX);
      }}
      onPointerMove={(e) => dragging.current && pick(e.clientX)}
      onPointerUp={() => (dragging.current = false)}
      onPointerCancel={() => (dragging.current = false)}
      onKeyDown={(e) => {
        if (disabled) return;
        const step = e.key === "ArrowRight" || e.key === "ArrowUp" ? snap : e.key === "ArrowLeft" || e.key === "ArrowDown" ? -snap : e.key === "PageUp" ? 60 : e.key === "PageDown" ? -60 : 0;
        if (step) {
          e.preventDefault();
          onChange(clamp(value + step));
        }
      }}
    >
      {/* end labels */}
      <span className="absolute left-0 top-0 text-xs font-semibold text-primary">Departs {toClock(start)}</span>
      <span className="absolute right-0 top-0 text-xs font-semibold text-primary">Arrives {toClock(start + duration)}</span>
      {/* whole window, then the permitted range */}
      <div className="absolute h-1.5 rounded-full bg-border" style={{ top: 34, left: PAD, right: PAD }} />
      <div className="absolute h-1.5 rounded-full bg-primary/45" style={{ top: 34, left: pos(min), width: `calc((100% - ${2 * PAD}px) * ${(hi - min) / duration})` }} />
      {ticks.map((t) => (
        <div key={t.offset} className="absolute" style={{ top: 42, left: pos(t.offset) }}>
          <div className={`-translate-x-1/2 bg-text-tertiary ${t.labelled ? "h-2.5 w-px" : "h-1.5 w-px"}`} />
          {t.labelled && <span className="absolute left-0 top-3 -translate-x-1/2 text-[11px] text-text-secondary">{t.text}</span>}
        </div>
      ))}
      {/* thumb */}
      <div
        className={`absolute h-5 w-5 -translate-x-1/2 rounded-full border-2 border-surface shadow ${disabled ? "bg-border" : "bg-primary"}`}
        style={{ top: 28, left: pos(Math.min(Math.max(value, 0), duration)) }}
      />
    </div>
  );
}
