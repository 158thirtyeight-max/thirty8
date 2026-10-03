import { redirect } from "next/navigation";

// The manual settlement screen was replaced by the weekly settlement engine (see /finance/settlements).
export default function LegacySettlementsPage() {
  redirect("/finance/settlements");
}
