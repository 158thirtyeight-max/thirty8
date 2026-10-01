import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/supabase_providers.dart';
import '../onboarding/validators.dart';

/// All buses of an operator, newest first. Still used by the service form.
final busesProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, operatorId) async {
  final supabase = ref.watch(supabaseProvider);
  return await supabase.from('buses').select().eq('operator_id', operatorId).order('created_at', ascending: false);
});

final busProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, busId) async {
  return await ref.watch(supabaseProvider).from('buses').select().eq('id', busId).single();
});

/// Verification state shown next to a bus. Mirrors bus_verification_state() in SQL:
/// legacy buses are never shown as verified.
String busVerificationState(Map<String, dynamic> bus) {
  if (bus['is_legacy'] == true) return 'legacy';
  final lifecycle = bus['lifecycle_status'] as String?;
  if ((lifecycle == 'approved' || lifecycle == 'active') && bus['approved_by'] != null) return 'verified';
  return 'unverified';
}

String busDisplayName(Map<String, dynamic> bus) {
  final name = (bus['name'] as String?)?.trim();
  final reg = bus['registration_number'] as String? ?? '';
  return (name == null || name.isEmpty) ? reg : '$name · $reg';
}

/// Admin-configured bus document requirements (scope = bus).
final busDocRequirementsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('document_requirements')
      .select()
      .eq('scope', 'bus')
      .eq('active', true)
      .order('sort_order');
  return List<Map<String, dynamic>>.from(rows);
});

final busDocumentsProvider = FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, busId) async {
  final rows = await ref.watch(supabaseProvider).from('bus_documents').select().eq('bus_id', busId).order('created_at');
  return List<Map<String, dynamic>>.from(rows);
});

class FleetRepository {
  FleetRepository(this._db);
  final SupabaseClient _db;

  /// Saves a bus document. [file] is optional when only the metadata (number /
  /// dates) of an existing document changes. Any change resets verification
  /// to pending (DB trigger).
  Future<void> saveBusDocument({
    required String operatorId,
    required String busId,
    required String docType,
    required String? docNumber,
    required DateTime? issueDate,
    required DateTime? expiryDate,
    PlatformFile? file,
    Map<String, dynamic>? existing,
  }) async {
    String? storagePath;
    String? fileName;
    if (file != null) {
      final path = file.path;
      if (path == null) throw Exception('Could not read the selected file');
      final problem = validateDocumentFile(fileName: file.name, sizeBytes: (await file.length()) ?? 0);
      if (problem != null) throw Exception(problem);
      final ext = file.name.split('.').last.toLowerCase();
      storagePath = '$operatorId/$busId/${docType}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await _db.storage.from('bus-documents').upload(storagePath, File(path));
      fileName = file.name;
    } else if (existing == null) {
      throw Exception('Please attach the document file');
    }

    String? d(DateTime? v) => v?.toIso8601String().substring(0, 10);
    final data = <String, dynamic>{
      'doc_number': (docNumber == null || docNumber.trim().isEmpty) ? null : docNumber.trim(),
      'issue_date': d(issueDate),
      'expiry_date': d(expiryDate),
      'file_path': ?storagePath,
      'file_name': ?fileName,
    };

    try {
      if (existing == null) {
        await _db.from('bus_documents').insert({'bus_id': busId, 'doc_type': docType, ...data});
      } else {
        await _db.from('bus_documents').update(data).eq('id', existing['id'] as String);
      }
    } catch (_) {
      // The file is stored but its record was not: remove it so nothing is left orphaned.
      if (storagePath != null) {
        try {
          await _db.storage.from('bus-documents').remove([storagePath]);
        } catch (_) {}
      }
      rethrow;
    }

    if (existing != null) {
      if (storagePath != null && existing['bucket'] == 'bus-documents') {
        try {
          await _db.storage.from('bus-documents').remove([existing['file_path'] as String]);
        } catch (_) {}
      }
    }
  }
}

final fleetRepositoryProvider = Provider<FleetRepository>((ref) => FleetRepository(ref.watch(supabaseProvider)));

/// Main-route locations (admin-managed, in main-route order): origin and destination pickers.
final citiesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('locations')
      .select('id, name, state, location_code')
      .eq('is_active', true)
      .eq('is_main_route_enabled', true)
      .order('main_route_order');
  return List<Map<String, dynamic>>.from(rows);
});

/// Every active location (one master list) with its pickup / drop flags, for intermediate stops. Read-only.
final stopLocationsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('locations')
      .select('id, name, location_code, is_main_route_enabled, is_pickup_enabled, is_drop_enabled')
      .eq('is_active', true)
      .order('pickup_order')
      .order('name');
  return List<Map<String, dynamic>>.from(rows);
});

/// Admin-managed route catalog (active routes with their ordered stops).
final routeCatalogProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final rows = await ref
      .watch(supabaseProvider)
      .from('route_templates')
      .select('*, stops:route_template_stops(*)')
      .eq('is_active', true)
      .order('name');
  return List<Map<String, dynamic>>.from(rows);
});

/// The bus's primary service plus its route and stop rows (all null/empty when nothing is configured yet).
final busRouteProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, busId) async {
  final db = ref.watch(supabaseProvider);
  final service = await db
      .from('bus_services')
      .select()
      .eq('bus_id', busId)
      .order('created_at')
      .limit(1)
      .maybeSingle();
  if (service == null) return {'service': null, 'route': null, 'boarding': <Map<String, dynamic>>[], 'dropping': <Map<String, dynamic>>[]};
  final routeId = service['route_id'] as String;
  final results = await Future.wait([
    db.from('bus_routes').select().eq('id', routeId).single(),
    db.from('boarding_points').select().eq('route_id', routeId).eq('is_active', true).order('sequence_no'),
    db.from('dropping_points').select().eq('route_id', routeId).eq('is_active', true).order('sequence_no'),
  ]);
  return {
    'service': service,
    'route': results[0],
    'boarding': List<Map<String, dynamic>>.from(results[1] as List),
    'dropping': List<Map<String, dynamic>>.from(results[2] as List),
  };
});

/// Fare rules and extra charges of the bus's primary service.
final busFaresProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, busId) async {
  final db = ref.watch(supabaseProvider);
  final service = await db.from('bus_services').select('id').eq('bus_id', busId).order('created_at').limit(1).maybeSingle();
  if (service == null) return {'service_id': null, 'rules': <Map<String, dynamic>>[], 'charges': <Map<String, dynamic>>[]};
  final serviceId = service['id'] as String;
  final results = await Future.wait([
    db.from('fare_rules').select().eq('service_id', serviceId),
    db.from('fare_charges').select().eq('service_id', serviceId).eq('active', true).order('created_at'),
  ]);
  return {
    'service_id': serviceId,
    'rules': List<Map<String, dynamic>>.from(results[0] as List),
    'charges': List<Map<String, dynamic>>.from(results[1] as List),
  };
});

/// Server-side setup checklist of a bus: {percent, complete, missing[], items[], details{}}.
final busCompletenessProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, busId) async {
  final res = await ref.watch(supabaseProvider).rpc('bus_completeness', params: {'p_bus_id': busId});
  return Map<String, dynamic>.from(res as Map);
});

/// {ready, blockers[]} — everything stopping this bus from being activated.
final busReadinessProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, busId) async {
  final res = await ref.watch(supabaseProvider).rpc('bus_activation_readiness', params: {'p_bus_id': busId});
  return Map<String, dynamic>.from(res as Map);
});
