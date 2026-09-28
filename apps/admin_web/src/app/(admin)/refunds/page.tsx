import { createClient } from "@/lib/supabase/server";
import { Badge, EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";
import { processRefund } from "./actions";
import ProcessButton from "./process-button";

type RefundRow = {
  id: string;
  amount_cents: number;
  reason: string | null;
  status: string;
  created_at: string;
  payments: {
    razorpay_payment_id: string | null;
    orders: {
      order_reference: string;
      orderable_type: string;
      profiles: { full_name: string | null; email: string | null } | null;
    } | null;
  } | null;
};

export default async function RefundsPage() {
  const supabase = await createClient();
  const { data: refunds } = await supabase
    .from("refunds")
    .select("id, amount_cents, reason, status, created_at, payments(razorpay_payment_id, orders(order_reference, orderable_type, profiles(full_name, email)))")
    .order("created_at", { ascending: false })
    .limit(200)
    .returns<RefundRow[]>();

  return (
    <div>
      <PageTitle title="Refunds" subtitle="Refund requests created by booking/shipment cancellations" />
      <Table>
        <thead>
          <tr>
            <Th>Order</Th>
            <Th>Customer</Th>
            <Th>Amount</Th>
            <Th>Reason</Th>
            <Th>Status</Th>
            <Th></Th>
          </tr>
        </thead>
        <tbody>
          {refunds?.map((r) => (
            <tr key={r.id}>
              <Td className="font-mono">
                {r.payments?.orders?.order_reference}
                <div className="font-sans text-text-tertiary capitalize">{r.payments?.orders?.orderable_type?.replace(/_/g, " ")}</div>
              </Td>
              <Td>{r.payments?.orders?.profiles?.full_name ?? r.payments?.orders?.profiles?.email ?? "—"}</Td>
              <Td>₹{(r.amount_cents / 100).toLocaleString("en-IN")}</Td>
              <Td>{r.reason}</Td>
              <Td>
                <Badge status={r.status} />
              </Td>
              <Td>{r.status === "pending" && <ProcessButton refundId={r.id} action={processRefund} />}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!refunds?.length && <EmptyState message="No refunds have been requested." />}
    </div>
  );
}
