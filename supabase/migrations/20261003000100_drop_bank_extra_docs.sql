-- Bank step no longer collects a cancelled cheque or an additional bank
-- document, and no longer asks for the bank address.
update public.document_requirements
   set active = false
 where doc_type in ('cancelled_cheque', 'bank_additional');
