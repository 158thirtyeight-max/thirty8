/* eslint-disable @typescript-eslint/no-explicit-any */

const KIND_STYLES: Record<string, string> = {
  bookable: "bg-success/20 border-success/40",
  unavailable: "bg-text-tertiary/25 border-text-tertiary/40",
  reserved: "bg-warning/25 border-warning/40",
  crew: "bg-primary/25 border-primary/40",
  other: "bg-text-secondary/20 border-text-secondary/40",
};

const ROLE_LABELS: Record<string, string> = {
  ladies: "Ladies reserved",
  accessible: "Accessible",
  driver: "Driver",
  conductor: "Conductor",
};

const KIND_LABELS: Record<string, string> = {
  bookable: "Available for booking",
  unavailable: "Not available",
  reserved: "Reserved",
  crew: "Driver / crew",
  other: "Other (non-bookable)",
};

/** Read-only render of a bus's seat layout (one grid per deck) exactly as the operator drew it. */
export function SeatLayoutView({ layout, seats }: { layout: any; seats: any[] }) {
  const cfg = (layout?.layout_json ?? {}) as { rows?: number; cols?: number; aisle_cols?: number[] };
  const rows = cfg.rows ?? Math.max(1, ...seats.map((s) => s.row_no ?? 1));
  const cols = cfg.cols ?? Math.max(1, ...seats.map((s) => s.col_no ?? 1));
  const aisles = new Set<number>(cfg.aisle_cols ?? []);
  const decks = Math.max(layout?.deck_count ?? 1, ...seats.map((s) => s.deck ?? 1));

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
                {Array.from({ length: cols }, (_, c) => c + 1).map((col) =>
                  aisles.has(col) ? (
                    <div key={col} className="h-10 w-5" />
                  ) : (
                    (() => {
                      const seat = byCell.get(`${deck}-${row}-${col}`);
                      return (
                        <div
                          key={col}
                          title={seat ? `${seat.seat_code} · ${(seat.role && ROLE_LABELS[seat.role]) || KIND_LABELS[seat.kind] || seat.kind}${seat.category ? ` · ${seat.category}` : ""}` : "empty"}
                          className={`m-0.5 flex h-10 w-10 items-center justify-center border text-[10px] font-medium ${
                            seat ? KIND_STYLES[seat.kind] ?? "" : "border-divider"
                          } ${seat?.seat_type === "sleeper" ? "rounded-sm" : "rounded-lg"} ${seat?.category === "premium" ? "ring-2 ring-primary" : ""}`}
                        >
                          {seat?.seat_code}
                        </div>
                      );
                    })()
                  ),
                )}
              </div>
            ))}
          </div>
        </div>
      ))}
      <div className="flex flex-wrap gap-3 text-xs text-text-secondary">
        {Object.entries(KIND_LABELS).map(([k, label]) => (
          <span key={k} className="flex items-center gap-1">
            <span className={`inline-block h-3 w-3 rounded-sm border ${KIND_STYLES[k]}`} />
            {label}
          </span>
        ))}
      </div>
    </div>
  );
}
