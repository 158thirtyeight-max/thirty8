-- Rollback for 20261003000200_gatea_enum_values.sql
-- PostgreSQL cannot drop enum values. The added values are unused once
-- 20261003000300_gatea_payment_integrity is rolled back, so this is a no-op by design.
select 1;
