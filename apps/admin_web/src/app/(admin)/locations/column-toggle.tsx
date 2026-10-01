"use client";

import { useEffect, useState, type ReactNode } from "react";

export type ToggleColumn = { key: string; label: string; defaultVisible: boolean };

const STORAGE_KEY = "locations.columns";

/** Column picker for the locations table; cells carry a `col-<key>` class that is hidden here. */
export function ColumnToggle({ columns, children }: { columns: ToggleColumn[]; children: ReactNode }) {
  const [visible, setVisible] = useState<Record<string, boolean>>(() => Object.fromEntries(columns.map((c) => [c.key, c.defaultVisible])));
  const [open, setOpen] = useState(false);

  useEffect(() => {
    try {
      const saved = JSON.parse(window.localStorage.getItem(STORAGE_KEY) ?? "null");
      if (saved && typeof saved === "object") setVisible((v) => ({ ...v, ...saved }));
    } catch {}
  }, []);

  function toggle(key: string) {
    setVisible((v) => {
      const next = { ...v, [key]: !v[key] };
      try {
        window.localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
      } catch {}
      return next;
    });
  }

  const css = columns
    .filter((c) => !visible[c.key])
    .map((c) => `.col-${c.key}{display:none}`)
    .join("");

  return (
    <div>
      <style>{css}</style>
      <div className="relative mb-3 flex justify-end">
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          className="rounded-md border border-border bg-surface px-3 py-1.5 text-sm font-medium text-text-primary transition hover:border-primary"
        >
          Columns ▾
        </button>
        {open && (
          <div className="absolute right-0 top-full z-10 mt-1 w-56 rounded-md border border-border bg-surface p-2 shadow-lg">
            {columns.map((c) => (
              <label key={c.key} className="flex cursor-pointer items-center gap-2 rounded px-2 py-1.5 text-sm hover:bg-primary/10">
                <input type="checkbox" checked={!!visible[c.key]} onChange={() => toggle(c.key)} />
                {c.label}
              </label>
            ))}
            <p className="px-2 pt-1 text-xs text-text-tertiary">Name and Actions are always shown.</p>
          </div>
        )}
      </div>
      {children}
    </div>
  );
}
