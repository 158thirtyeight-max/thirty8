"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type Sync = "connecting" | "live" | "reconnecting" | "offline";

/**
 * Keeps the server-rendered trip page current. The database sends tiny "something changed" pings on
 * private Broadcast channels (seats / ops / tracking); we never trust the ping's content — we re-run
 * the page's authorized queries (router.refresh). A 60 s timer and a manual button reconcile if a
 * ping is missed, and the label says when the page was last refreshed.
 */
export function LiveRefresh({ tripId }: { tripId: string }) {
  const router = useRouter();
  const [sync, setSync] = useState<Sync>("connecting");
  const [at, setAt] = useState<Date>(new Date());
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    const supabase = createClient();
    let alive = true;

    const refresh = () => {
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(() => {
        router.refresh();
        setAt(new Date());
      }, 400);
    };

    const channels: ReturnType<typeof supabase.channel>[] = [];
    (async () => {
      const { data } = await supabase.auth.getSession();
      if (data.session) supabase.realtime.setAuth(data.session.access_token);
      if (!alive) return;
      for (const [suffix, event] of [["seats", "seat_changes"], ["ops", "changed"], ["track", "tracking"]] as const) {
        const ch = supabase.channel(`trip:${tripId}:${suffix}`, { config: { private: true } });
        ch.on("broadcast", { event }, refresh).subscribe((status) => {
          if (suffix !== "seats") return;
          if (status === "SUBSCRIBED") {
            setSync("live");
            refresh(); // anything may have changed while we were not listening
          } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") setSync("reconnecting");
          else if (status === "CLOSED") setSync("offline");
        });
        channels.push(ch);
      }
    })();

    const interval = setInterval(() => {
      router.refresh();
      setAt(new Date());
    }, 60_000);

    return () => {
      alive = false;
      clearInterval(interval);
      if (timer.current) clearTimeout(timer.current);
      channels.forEach((c) => supabase.removeChannel(c));
    };
  }, [tripId, router]);

  const label =
    sync === "live" ? "Live" : sync === "reconnecting" ? "Reconnecting…" : sync === "offline" ? "Offline — refreshing every minute" : "Connecting…";
  const color = sync === "live" ? "text-success" : "text-warning";

  return (
    <div className="mb-4 flex items-center gap-3 text-xs">
      <span className={color}>● {label}</span>
      <span className="text-text-tertiary">updated {at.toLocaleTimeString("en-GB", { hour12: true })}</span>
      <button
        type="button"
        onClick={() => {
          router.refresh();
          setAt(new Date());
        }}
        className="rounded-md border border-border px-2 py-1 text-text-secondary hover:border-primary hover:text-primary"
      >
        Refresh
      </button>
    </div>
  );
}
