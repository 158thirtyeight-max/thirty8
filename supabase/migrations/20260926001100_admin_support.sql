-- =========================================================================
-- Admin verification dashboard support (Phase 12)
-- =========================================================================

-- Bus-scoped audit entries carry the bus id in `after`; index them so the
-- bus activity timeline stays fast (operator-scoped entries were indexed in
-- the approval-workflow migration).
create index if not exists audit_logs_after_bus_idx on public.audit_logs ((after ->> 'bus_id'))
  where after ? 'bus_id';
