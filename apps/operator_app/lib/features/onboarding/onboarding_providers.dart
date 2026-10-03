import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';
import 'validators.dart';

const operatorDocumentsBucket = 'operator-documents';

/// Business/profile details saved so far (empty map before step 1 is saved).
final operatorProfileProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, operatorId) async {
  final row = await ref
      .watch(supabaseProvider)
      .from('operator_profiles')
      .select()
      .eq('operator_id', operatorId)
      .maybeSingle();
  return row ?? <String, dynamic>{};
});

final operatorKycProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, operatorId) async {
  final row = await ref
      .watch(supabaseProvider)
      .from('operator_kyc')
      .select()
      .eq('operator_id', operatorId)
      .maybeSingle();
  return row ?? <String, dynamic>{};
});

final operatorBankProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, operatorId) async {
  final row = await ref
      .watch(supabaseProvider)
      .from('operator_bank_details')
      .select()
      .eq('operator_id', operatorId)
      .maybeSingle();
  return row ?? <String, dynamic>{};
});

/// The uploaded payment mandate (null until one is uploaded).
final operatorMandateProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>?, String>((ref, operatorId) async {
  return ref
      .watch(supabaseProvider)
      .from('operator_payment_mandates')
      .select()
      .eq('operator_id', operatorId)
      .maybeSingle();
});

final operatorDocumentsProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('operator_documents')
      .select()
      .eq('operator_id', operatorId)
      .order('created_at');
  return List<Map<String, dynamic>>.from(rows);
});

/// Admin-configurable requirements for the operator scope.
final operatorDocRequirementsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('document_requirements')
      .select()
      .eq('scope', 'operator')
      .eq('active', true)
      .order('sort_order');
  return List<Map<String, dynamic>>.from(rows);
});

/// {percent, complete, missing[], items[]} from the server-side
/// operator_completeness() — the same function the submit RPC will enforce.
final operatorCompletenessProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, operatorId) async {
  final res = await ref
      .watch(supabaseProvider)
      .rpc('operator_completeness', params: {'p_operator_id': operatorId});
  return Map<String, dynamic>.from(res as Map);
});

class OnboardingRepository {
  OnboardingRepository(this._db);
  final SupabaseClient _db;

  /// Step 1. Creates the operator on first save (via register_operator, which
  /// also grants operator_admin), otherwise updates it. Returns the operator id.
  Future<String> saveBusiness({
    required String? operatorId,
    required String name,
    required String legalName,
    required String businessType,
    required String email,
    required String phone,
    required Map<String, dynamic> profile,
  }) async {
    var id = operatorId;
    if (id == null) {
      final created = await _db.rpc('register_operator', params: {
        'p_name': name,
        'p_legal_name': legalName,
        'p_business_type': businessType,
        'p_contact_email': email,
        'p_contact_phone': phone,
      });
      id = (created as Map)['id'] as String;
    } else {
      await _db.from('operators').update({
        'name': name,
        'legal_name': legalName,
        'business_type': businessType,
        'contact_email': email,
        'contact_phone': phone,
      }).eq('id', id);
    }
    await _db.from('operator_profiles').upsert({...profile, 'operator_id': id});
    await _setStep(id, 2);
    return id;
  }

  /// Step 2 fields (documents are uploaded separately).
  Future<void> saveKyc({
    required String operatorId,
    required String? pan,
    required bool? gstRegistered,
    required String? gstin,
  }) async {
    await _db.from('operator_kyc').upsert({
      'operator_id': operatorId,
      'pan_number': (pan == null || pan.trim().isEmpty) ? null : Validators.normalizePan(pan),
      'gst_registered': gstRegistered,
      'gstin': (gstRegistered == true && gstin != null && gstin.trim().isNotEmpty)
          ? Validators.normalizeGstin(gstin)
          : null,
    });
  }

  Future<void> saveBank({
    required String operatorId,
    required String holder,
    required String bankName,
    required String branch,
    required String accountNumber,
    required String ifsc,
    required String micr,
    required String? accountType,
  }) async {
    String? n(String v) => v.trim().isEmpty ? null : v.trim();
    await _db.from('operator_bank_details').upsert({
      'operator_id': operatorId,
      'account_holder_name': n(holder),
      'bank_name': n(bankName),
      'branch_name': n(branch),
      'account_number': n(Validators.normalizeDigits(accountNumber)),
      'ifsc': n(Validators.normalizeIfsc(ifsc)),
      'micr': n(Validators.normalizeDigits(micr)),
      'account_type': accountType,
    });
  }

  /// Reads the picked file's bytes. On Android the picker often returns a
  /// content:// URI with no local path, so never rely on `file.path`.
  Future<Uint8List> _readBytes(PlatformFile file) async {
    try {
      return await file.readAsBytes();
    } catch (_) {
      throw Exception('Could not read the selected file. Please pick it again.');
    }
  }

  /// Uploads the signed & stamped mandate. Replacing resets verification
  /// (enforced by a DB trigger).
  Future<void> uploadMandate({
    required String operatorId,
    required PlatformFile file,
    required String templateVersion,
    String? existingPath,
  }) async {
    final bytes = await _readBytes(file);
    final problem = validateDocumentFile(fileName: file.name, sizeBytes: bytes.length);
    if (problem != null) throw Exception(problem);

    final ext = file.name.split('.').last.toLowerCase();
    final storagePath = '$operatorId/payment_mandate_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage.from(operatorDocumentsBucket).uploadBinary(storagePath, bytes);
    await _db.from('operator_payment_mandates').upsert({
      'operator_id': operatorId,
      'file_path': storagePath,
      'file_name': file.name,
      'template_version': templateVersion,
    });
    if (existingPath != null) {
      try {
        await _db.storage.from(operatorDocumentsBucket).remove([existingPath]);
      } catch (_) {}
    }
  }

  Future<void> _setStep(String operatorId, int step) async {
    // Only ever move forward so revisiting an earlier step doesn't lose progress.
    final row = await _db.from('operators').select('onboarding_step').eq('id', operatorId).maybeSingle();
    final current = (row?['onboarding_step'] as int?) ?? 1;
    if (step > current) {
      await _db.from('operators').update({'onboarding_step': step}).eq('id', operatorId);
    }
  }

  Future<void> markStep(String operatorId, int step) => _setStep(operatorId, step);

  /// Uploads [file] to the private bucket and records/replaces the document
  /// row. Replacing resets verification to pending (enforced by a DB trigger).
  Future<void> uploadDocument({
    required String operatorId,
    required String docType,
    required PlatformFile file,
    String? existingDocId,
    String? existingPath,
  }) async {
    final bytes = await _readBytes(file);
    final problem = validateDocumentFile(fileName: file.name, sizeBytes: bytes.length);
    if (problem != null) throw Exception(problem);

    final ext = file.name.split('.').last.toLowerCase();
    final storagePath = '$operatorId/${docType}_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage.from(operatorDocumentsBucket).uploadBinary(storagePath, bytes);

    if (existingDocId != null && docType != 'other_registration') {
      await _db.from('operator_documents').update({
        'file_path': storagePath,
        'file_name': file.name,
      }).eq('id', existingDocId);
      if (existingPath != null) {
        try {
          await _db.storage.from(operatorDocumentsBucket).remove([existingPath]);
        } catch (_) {
          // Orphaned old file is harmless; the row already points at the new one.
        }
      }
    } else {
      await _db.from('operator_documents').insert({
        'operator_id': operatorId,
        'doc_type': docType,
        'file_path': storagePath,
        'file_name': file.name,
      });
    }
  }

  Future<void> deleteDocument({required String docId, required String path}) async {
    await _db.from('operator_documents').delete().eq('id', docId);
    try {
      await _db.storage.from(operatorDocumentsBucket).remove([path]);
    } catch (_) {}
  }

  /// Uploads the optional business logo to the existing public bucket.
  Future<String> uploadLogo({required String operatorId, required String filePath}) async {
    final ext = filePath.split('.').last.toLowerCase();
    final path = '$operatorId/logo_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await _db.storage.from('operator-logos').upload(path, File(filePath));
    return path;
  }
}

final onboardingRepositoryProvider =
    Provider<OnboardingRepository>((ref) => OnboardingRepository(ref.watch(supabaseProvider)));
