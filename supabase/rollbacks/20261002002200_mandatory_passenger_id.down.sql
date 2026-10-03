drop function if exists public.log_manifest_export(uuid, text);
delete from public.platform_settings where key = 'passenger_id_required';
-- create_booking and get_trip_manifest: re-run the previous definitions from 20261002000300_booking_window_enforcement.sql and 20261002001800_passenger_identity_boarding.sql
