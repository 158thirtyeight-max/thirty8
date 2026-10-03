import { login } from "./actions";
import { Button } from "@/components/ui";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="w-full max-w-sm">
        <div className="mb-8 text-center">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/brand/thirty8-plus-mark.png" alt="38 Admin" className="mx-auto h-14 w-14" />
          <h1 className="mt-3 text-2xl font-semibold text-text-primary">
            38 <span className="font-normal text-text-tertiary">Admin</span>
          </h1>
          <p className="mt-1 text-sm text-text-secondary">Platform control panel</p>
        </div>

        <form action={login} className="space-y-4 rounded-xl border border-border bg-surface p-6">
          <div>
            <label className="mb-1 block text-sm text-text-secondary" htmlFor="email">
              Email
            </label>
            <input
              id="email"
              name="email"
              type="email"
              required
              className="w-full rounded-lg border border-border bg-background px-3 py-2 text-text-primary outline-none focus:border-primary"
            />
          </div>
          <div>
            <label className="mb-1 block text-sm text-text-secondary" htmlFor="password">
              Password
            </label>
            <input
              id="password"
              name="password"
              type="password"
              required
              className="w-full rounded-lg border border-border bg-background px-3 py-2 text-text-primary outline-none focus:border-primary"
            />
          </div>

          {error && (
            <p className="rounded-lg bg-error/15 px-3 py-2 text-sm text-error">
              {error === "not_authorized" ? "That account is not a platform admin." : error}
            </p>
          )}

          <Button type="submit" className="w-full">
            Log in
          </Button>
        </form>
      </div>
    </div>
  );
}
