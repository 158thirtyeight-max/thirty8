/* eslint-disable @typescript-eslint/no-explicit-any */

const STATUS_STYLES: Record<string, string> = {
  available: "bg-success/15 border-success text-text-primary",
  held: "bg-warning/20 border-warning text-text-primary",
  booked: "bg-primary/25 border-primary text-text-primary",
  boarded: "bg-secondary/25 border-secondary text-text-primary",
  blocked: "bg-text-tertiary/25 border-text-tertiary text-text-secondary",
  cancelled: "bg-error/15 border-error text-text-primary",
};

const STATUS_LABELS: Record<string, string> = {
  available: "Available",
  held: "Held (checking out)",
  booked: "Booked",
  boarded: "Boarded",
  blocked: "Blocked",
};

const STATUS_MARK: Record<string, string> = { held: "⏳", booked: "●", boarded: "✓", blocked: "⛔" };

/**
 * A bus drawn from its real configuration with each seat's live status (colour + mark + title, so
 * it never relies on colour alone). Seats come from get_operator_trip_seat_map: booking reference
 * and status only, never passenger data.
 */
export function SeatStatusMap({ layout, seats }: { layout: any; seats: any[] }) {
  const cfg = (layout ?? {}) as { rows?: number; cols?: number; aisle_cols?: number[] };
  const rows = cfg.rows ?? Math.max(1, ...seats.map((s) => s.row_no ?? 1));
  const cols = cfg.cols ?? Math.max(1, ...seats.map((s) => s.col_no ?? 1));
  const aisles = new Set<number>(cfg.aisle_cols ?? []);
  const decks = Math.max(1, ...seats.map((s) => s.deck ?? 1));
  const byCell = new Map<string, any>();
  for (const s of seats) byCell.set(`${s.deck}-${s.row_no}-${s.col_no}`, s);

  return (
    <div className="space-y-4">
      {Array.from({ length: decks }, (_, d) => d + 1).map((deck) => (
        <div key={deck}>
          {decks > 1 && <p className="mb-1 text-xs text-text-secondary">{deck === 1 ? "Lower deck" : "Upper deck"}</p>}
          <div className="inline-block rounded-lg border border-border p-2">
            {Array.from({ length: rows }, (_, r) => r + 1).map((row) => (
              <div key={row} className="flex">
                {Array.from({ length: cols }, (_, c) => c + 1).map((col) => {
                  if (aisles.has(col)) return <div key={col} className="h-11 w-5" />;
                  const seat = byCell.get(`${deck}-${row}-${col}`);
                  if (!seat) return <div key={col} className="m-0.5 h-11 w-11" />;
                  return (
                    <div
                      key={col}
                      title={`${seat.seat_code} · ${STATUS_LABELS[seat.status] ?? seat.status}${seat.booking_reference ? ` · ${seat.booking_reference} (${seat.booking_status})` : ""}`}
                      className={`m-0.5 flex h-11 w-11 flex-col items-center justify-center border text-[10px] font-medium ${STATUS_STYLES[seat.status] ?? ""} ${
                        seat.seat_type === "sleeper" ? "rounded-sm" : "rounded-lg"
                      }`}
                    >
                      <span>{seat.seat_code}</span>
                      <span className="text-[9px] leading-none">{STATUS_MARK[seat.status] ?? ""}</span>
                    </div>
                  );
                })}
              </div>
            ))}
          </div>
        </div>
      ))}
      <div className="flex flex-wrap gap-3 text-xs text-text-secondary">
        {Object.entries(STATUS_LABELS).map(([k, label]) => (
          <span key={k} className="flex items-center gap-1">
            <span className={`inline-block h-3 w-3 rounded-sm border ${STATUS_STYLES[k]}`} />
            {label}
          </span>
        ))}
      </div>
    </div>
  );
}
