-- Rolls back 20261002001800_passenger_identity_boarding.sql.
-- WARNING: drops stored passenger identity documents and boarding verification state.
drop trigger if exists ping_ops_pboarding_upd on public.passenger_boarding;
drop trigger if exists ping_ops_pboarding_ins on public.passenger_boarding;
drop function if exists private.ping_trip_ops_boarding();
drop function if exists public.reveal_passenger_document(uuid, text);
drop function if exists public.correct_boarding(uuid, text);
drop function if exists public.mark_boarding_exception(uuid, text);
drop function if exists public.confirm_boarding(uuid);
drop function if exists public.verify_passenger_boarding(uuid, boolean, text);
drop function if exists private.do_board(uuid, text);
drop function if exists private.lock_boarding_item(uuid);
drop function if exists private.log_boarding(uuid, uuid, text);
drop function if exists public.get_trip_manifest(uuid, text, text);
drop function if exists private.trip_for_staff(uuid, boolean);
drop function if exists public.attach_passenger_documents(text, jsonb);
drop function if exists private.store_passenger_identity(uuid, text, text);
drop function if exists private.document_label(text);
drop function if exists private.mask_document(text, text);
drop function if exists private.normalize_document(text, text);
drop table if exists public.passenger_boarding;
drop table if exists public.passenger_identity;
delete from public.boarding_events where result in ('verified', 'exception', 'corrected');
alter table public.boarding_events drop constraint boarding_events_result_check;
alter table public.boarding_events add constraint boarding_events_result_check
  check (result in ('boarded', 'rejected_already_used', 'rejected_invalid', 'rejected_wrong_trip'));
-- verify_ticket_qr: restore the original raising version from 20260923002300_manifest_and_qr_functions.sql
-- (re-run that function definition); the id_doc_key secret is intentionally kept.
