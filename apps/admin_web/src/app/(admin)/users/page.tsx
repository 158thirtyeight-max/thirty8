import { createClient } from "@/lib/supabase/server";
import { EmptyState, PageTitle, Table, Td, Th } from "@/components/ui";

type ProfileRow = {
  id: string;
  full_name: string | null;
  email: string | null;
  phone: string | null;
  created_at: string;
  user_roles: { role: string; operators: { name: string } | null }[];
};

export default async function UsersPage() {
  const supabase = await createClient();
  const { data: profiles } = await supabase
    .from("profiles")
    .select("id, full_name, email, phone, created_at, user_roles(role, operators(name))")
    .order("created_at", { ascending: false })
    .limit(200)
    .returns<ProfileRow[]>();

  return (
    <div>
      <PageTitle title="Users" subtitle="Everyone with a Thirty8 account (most recent 200)" />
      <Table>
        <thead>
          <tr>
            <Th>Name</Th>
            <Th>Contact</Th>
            <Th>Roles</Th>
            <Th>Joined</Th>
          </tr>
        </thead>
        <tbody>
          {profiles?.map((p) => (
            <tr key={p.id}>
              <Td>{p.full_name ?? "—"}</Td>
              <Td>
                <div>{p.email ?? "—"}</div>
                <div className="text-slate-500">{p.phone ?? ""}</div>
              </Td>
              <Td>
                {p.user_roles?.length
                  ? p.user_roles
                      .map((r) => (r.operators?.name ? `${r.role} @ ${r.operators.name}` : r.role))
                      .join(", ")
                  : "customer"}
              </Td>
              <Td>{new Date(p.created_at).toLocaleDateString()}</Td>
            </tr>
          ))}
        </tbody>
      </Table>
      {!profiles?.length && <EmptyState message="No users yet." />}
    </div>
  );
}
