# shared_types

`database.types.ts` — generated Supabase Postgres types (tables, enums, function
signatures). Regenerate after any schema change:

```bash
supabase gen types typescript --project-id xdrthrdwdfzhzhqkhnnf > database.types.ts
```

Used by `apps/admin_web` (Next.js) directly; `apps/customer_app` and
`apps/operator_app` (Flutter/Dart) don't consume this directly but the enum
values and table/column names here should stay the source of truth for the
Dart model classes.
