# Thirty8 Design System

Single source of truth for the visual language shared by the customer app, the
operator app, and the admin web dashboard. **Status: tokens, theme
infrastructure, the shared component library, and the migration of all three
apps' existing screens onto them are live** — see "What's not done yet" at
the bottom for the handful of things intentionally left out.

## Brand direction

- Modern, clean, premium, minimal "soft UI": rounded cards, generous
  spacing, soft purple-tinted shadows, clear hierarchy.
- Primary identity color is purple/indigo (`#6D28D9` family). Extracted from
  a job-board reference app as a *style* reference only — no content,
  icons, or layout were copied from it.
- Customer, operator, and admin apps have different workflows but must look
  like one product family: same colors, type scale, spacing, radius,
  shadows, and component shapes.

## Source of truth

- **[`design-system/tokens.json`](design-system/tokens.json)** — platform-neutral
  token values (colors, typography scale, spacing, radius, shadows).
- **[`packages/design_system`](packages/design_system)** — Flutter package
  implementing those tokens as Dart constants + a shared `ThemeData`.
  `customer_app` and `operator_app` both depend on it via a path dependency
  and must not redefine their own `theme.dart`.
- **`apps/admin_web/src/app/globals.css`** — the same tokens as CSS custom
  properties, mapped into a Tailwind v4 `@theme inline` block so they're
  available as ordinary utilities (`bg-primary`, `text-text-secondary`,
  `rounded-lg`, `shadow-md`, etc).

If a value needs to change, change it in `tokens.json` first, then update
the two implementations to match. Never hardcode a color, radius, or shadow
value directly in a screen/component in any app.

## Colors

| Token | Hex (light / Flutter) | Hex (dark / admin) | Usage |
|---|---|---|---|
| `primary` | `#6D28D9` | `#8B5CF6` | Brand color — primary buttons, active nav, links |
| `primaryDark` | `#4C1D95` | `#6D28D9` | Pressed states, shadow tint |
| `primaryLight` | `#C4B5FD` | `#C4B5FD` | Chip/badge backgrounds, subtle highlights |
| `secondary` | `#4F46E5` | `#4F46E5` | Secondary actions, info accents |
| `accent` | `#F59E0B` | `#F59E0B` | Promo highlights, warning-adjacent CTAs |
| `background` | `#F8F7FC` | `#0B0712` | Screen/page background |
| `surface` / `card` | `#FFFFFF` | `#1D1530` | Cards, sheets, inputs |
| `surfaceElevated` | `#FFFFFF` | `#1D1530` | Modals, popovers |
| `textPrimary` | `#1E1B2E` | `#F5F3FA` | Headings, primary copy |
| `textSecondary` | `#615C73` | `#B3ACC6` | Secondary copy, labels |
| `textTertiary` | `#9B96AC` | `#7C7690` | Placeholder, disabled-adjacent text |
| `border` | `#E7E3F0` | `#2D2542` | Card/input borders |
| `divider` | `#EFECF7` | `#251D3A` | Hairline separators |
| `success` | `#10B981` | same | Confirmed, delivered, approved |
| `warning` | `#F59E0B` | same | Pending, draft, processing |
| `error` | `#EF4444` | same | Rejected, failed, cancelled |
| `info` | `#3B82F6` | same | Informational banners |
| `disabled` | `#C9C5D6` | `#4A4460` | Disabled controls |

Admin web stays a fixed dark theme (internal tool, no light mode) but uses
the same hue family so it visually belongs with the mobile apps.

## Typography

Font: **Inter** everywhere (Flutter via `google_fonts`, Next.js via
`next/font/google`). Monospace (`Geist Mono`) is unchanged in admin web —
it's only used for incidental code/id display, not part of the brand type.

| Style | Size | Weight | Line height | Use |
|---|---|---|---|---|
| Display | 34 | 700 | 1.15 | Hero numbers, splash |
| H1 | 28 | 700 | 1.2 | Page titles |
| H2 | 24 | 700 | 1.25 | Section headers |
| H3 | 20 | 600 | 1.3 | Card/dialog titles |
| H4 | 18 | 600 | 1.35 | Sub-section titles |
| Body Large | 16 | 400 | 1.5 | Primary reading text |
| Body | 14 | 400 | 1.5 | Default UI text |
| Body Small | 13 | 400 | 1.45 | Secondary UI text |
| Caption | 12 | 400 | 1.4 | Timestamps, meta |
| Button | 15 | 600 | 1.2 | Button labels |
| Label | 13 | 500 | 1.3 | Form labels, chips |
| Nav Label | 12 | 500 | 1.2 | Bottom nav / tab labels |

## Spacing

`xs 4` · `sm 8` · `md 16` · `lg 24` · `xl 32` · `2xl 48` · `3xl 64` (px/dp).
Flutter: `AppSpacing.md`. Tailwind's own numeric spacing scale (`p-4`,
`gap-6`, ...) already lines up with this scale — no separate Tailwind
spacing tokens were added.

## Radius

`sm 8` · `md 12` · `lg 16` · `xl 24` · `pill 999`.
Flutter: `AppRadius.mdRadius` (a `BorderRadius`, not just a `double`).
Tailwind: `rounded-sm|md|lg|xl|pill` — these override Tailwind's default
radius scale to match.

## Shadows

`none` · `sm` · `md` · `lg` — all soft and purple-tinted
(`rgba(76, 29, 149, …)`), never a flat black box-shadow.
Flutter: `AppShadows.md` (a `List<BoxShadow>`). Tailwind: `shadow-sm|md|lg`.

## Components

`ThemeData` in `packages/design_system/lib/src/app_theme.dart` already
styles, from the tokens above: buttons (elevated/outlined/text/icon/FAB),
cards, text fields, chips, dialogs, bottom sheets, snackbars, dividers,
navigation bar, tab bar, switches, checkboxes, radios, progress indicators.
Any Flutter widget using the default theme (i.e. not passing an inline
`style:`) already gets the new look for free.

On top of that, `packages/design_system` exports a small reusable widget
library (`packages/design_system/lib/src/components/`) — use these instead
of hand-rolling the same layout in every screen:

| Widget | Purpose |
|---|---|
| `AppButton` | `primary`/`secondary`/`outline`/`ghost`/`destructive` variants, `medium`/`small` sizes, optional icon/loading state |
| `AppCard`, `AppStatCard` | `standard`/`elevated`/`interactive` card variants; `AppStatCard` is the label+value dashboard tile |
| `AppTextField`, `AppSearchField` | Standard input and a pre-configured search field |
| `AppBadge` | Pill-shaped status badge — same status→color map as admin web's `Badge` (see table below) |
| `AppChip` | Neutral/primary filter or tag chip, selectable |
| `AppEmptyState`, `AppLoadingState`, `AppErrorState` | The three placeholder states every list/detail screen needs; `AppErrorState` includes an optional retry `AppButton` |
| `AppSectionHeader`, `AppListItem` | Section label with optional trailing action; a standard leading/title/subtitle/trailing list row |

Admin web mirrors the same set in one file,
`apps/admin_web/src/components/ui.tsx`: `PageTitle`, `StatCard`,
`Table`/`Th`/`Td`, `Badge`, `EmptyState`, `LoadingState`, `ErrorState`,
`SectionHeader`, and `Button` (with the same five variants as `AppButton`).
All of them now use the semantic tokens (`bg-primary`, `text-text-secondary`,
`bg-success/15 text-success`, `rounded-lg`, `shadow-sm`, ...) instead of raw
`slate`/`emerald`/`amber`/`red` Tailwind classes.

**Status → color mapping** (kept in sync between `AppBadge` and admin's
`Badge`): `approved` / `active` / `captured` / `confirmed` / `delivered` →
`success`; `pending` / `draft` / `processing` → `warning`; `rejected` /
`suspended` / `cancelled` / `failed` → `error`; anything else falls back to
the neutral tertiary/slate tone. Add a new status to *both* maps together.

## Screen migration status

All existing screens in all three apps have been migrated onto the tokens
and shared components above — buttons, cards, text fields, badges,
empty/loading/error states, section headers, and list rows now go through
`AppButton`/`AppCard`/`AppTextField`/`AppBadge`/`AppEmptyState`/
`AppLoadingState`/`AppErrorState`/`AppSectionHeader`/`AppListItem` (Flutter)
or `Button`/`StatCard`/`Table`/`Badge`/`EmptyState`/`LoadingState`/
`ErrorState`/`SectionHeader` (admin web) instead of hand-rolled markup.
Business logic, Riverpod state, Supabase/RPC calls, server actions, and
routing were left untouched everywhere — this was a presentation-only pass.
`flutter analyze` is clean on both Flutter apps and `next build` succeeds on
admin web.

A few files were deliberately left as-is because nothing matched:
- Flutter: `TextFormField`s with a `validator` (forms) were kept rather
  than converted to `AppTextField`, which doesn't support validators — this
  applies across the auth/booking/bus_ops/service forms.
  `operator_app`'s `home_shell.dart`, `bus_ops_tab.dart`, and
  `cargo_ops_tab.dart` are pure tab/navigation scaffolding with nothing to
  restyle. `SeatColors` (customer_app) and seat-map coloring are untouched —
  domain-specific availability coloring, not decorative chrome.
- Admin web: `bookings/page.tsx`, `dashboard/page.tsx`, `audit-logs/page.tsx`,
  `shipments/page.tsx` already used only shared components/tokens.

## What's not done yet

1. No shared icon-family decision has been made yet (Flutter screens
   currently use Material icons directly; admin web has no icon set at
   all).
2. No dark-mode variant exists for the two Flutter apps beyond
   `AppTheme.dark()` being defined (apps currently launch in light mode by
   default — verify before enabling a theme switcher).
3. `AppTextField` doesn't support form `validator`s, so screens using
   `Form`/`TextFormField` for validation were intentionally left on
   `TextFormField` rather than losing validation — if a validated-input
   design-system widget is wanted later, extend `AppTextField` (e.g. via an
   optional `validator` param) rather than forcing every form onto
   `TextField`.

## Future-feature rule

Before adding any new UI:

1. Check this file and `design-system/tokens.json`.
2. Use `design_system` package tokens (Flutter) or the CSS/Tailwind tokens
   (admin web) — never a new hardcoded color/radius/shadow value.
3. Reuse an existing `ThemeData`-styled widget (button/card/input/etc)
   before writing custom styling.
4. If a genuinely new reusable pattern is needed, add it to
   `packages/design_system` (Flutter) or `components/ui.tsx` (admin web),
   and document it here.
