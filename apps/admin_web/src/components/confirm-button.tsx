"use client";

import type { ButtonHTMLAttributes, ReactNode } from "react";
import { Button } from "@/components/ui";

/** A submit button that asks for confirmation before the form action runs. */
export function ConfirmButton({
  message,
  children,
  onClick,
  ...rest
}: { message: string; children: ReactNode } & ButtonHTMLAttributes<HTMLButtonElement> & { variant?: "primary" | "secondary" | "outline" | "ghost" | "destructive" }) {
  return (
    <Button
      type="submit"
      onClick={(e) => {
        if (!window.confirm(message)) e.preventDefault();
        else onClick?.(e);
      }}
      {...rest}
    >
      {children}
    </Button>
  );
}
