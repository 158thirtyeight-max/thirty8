"use client";

import { useState, useTransition } from "react";

/**
 * One refund workflow step. `askReason` prompts for a mandatory reason (rejection);
 * `confirmText` asks for confirmation first (executing a refund moves real money).
 */
export default function ProcessButton({
  refundId,
  action,
  label,
  pendingLabel,
  variant = "primary",
  askReason = false,
  confirmText,
}: {
  refundId: string;
  action: (id: string, reason?: string) => Promise<unknown>;
  label: string;
  pendingLabel?: string;
  variant?: "primary" | "outline" | "destructive";
  askReason?: boolean;
  confirmText?: string;
}) {
  const [isPending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const style =
    variant === "primary"
      ? "bg-primary text-white hover:bg-primary-dark"
      : variant === "destructive"
        ? "bg-error text-white hover:opacity-90"
        : "border border-border text-text-primary hover:border-primary hover:text-primary";

  return (
    <div>
      <button
        disabled={isPending}
        onClick={() => {
          let reason: string | undefined;
          if (askReason) {
            reason = window.prompt("Reason (required):")?.trim();
            if (!reason) return;
          } else if (confirmText && !window.confirm(confirmText)) {
            return;
          }
          startTransition(async () => {
            setError(null);
            try {
              await action(refundId, reason);
            } catch (e) {
              setError(e instanceof Error ? e.message : "Action failed");
            }
          });
        }}
        className={`rounded-md px-3 py-1.5 text-xs font-medium disabled:opacity-50 ${style}`}
      >
        {isPending ? (pendingLabel ?? "Working…") : label}
      </button>
      {error && <p className="mt-1 max-w-xs text-xs text-error">{error}</p>}
    </div>
  );
}
