import 'package:supabase_flutter/supabase_flutter.dart';

import 'numbering.dart';
import 'seat_layout_model.dart';

/// Storage used by the wizard; lets the UI run against fake data (see
/// demo/seat_layout_demo.dart) as well as Supabase.
abstract class SeatLayoutStore {
  Future<SeatLayoutDraft> load(String busId, {required int fallbackCapacity});
  Future<void> saveDraft(String busId, SeatLayoutDraft d);
  Future<void> save(String busId, SeatLayoutDraft d);
}

/// Loads and saves seat layouts. No schema changes: wizard config lives in
/// `bus_layouts.layout_json` (v2), and only passenger seats become `seats`
/// rows. Saving always creates a new layout version so trips that already
/// reference old `seats` rows (trip_seats FK) are never touched.
class SeatLayoutRepository implements SeatLayoutStore {
  SeatLayoutRepository(this._db);
  final SupabaseClient _db;

  Future<Map<String, dynamic>?> _draftRow(String busId) async {
    final rows = await _db
        .from('bus_layouts')
        .select()
        .eq('bus_id', busId)
        .eq('is_active', false)
        .contains('layout_json', {'draft': true})
        .order('created_at', ascending: false)
        .limit(1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Draft if one exists, else the active layout, else a fresh draft.
  @override
  Future<SeatLayoutDraft> load(String busId, {required int fallbackCapacity}) async {
    final draft = await _draftRow(busId);
    if (draft != null) {
      return SeatLayoutDraft.fromJson(Map<String, dynamic>.from(draft['layout_json'] as Map), fallbackCapacity: fallbackCapacity);
    }
    final active = await _db.from('bus_layouts').select().eq('bus_id', busId).eq('is_active', true).maybeSingle();
    if (active != null) {
      final d = SeatLayoutDraft.fromJson(Map<String, dynamic>.from(active['layout_json'] as Map), fallbackCapacity: fallbackCapacity);
      if (d.cells.isEmpty) {
        // Legacy layout saved before the wizard: rebuild the grid from its seats.
        final seats = await _db.from('seats').select('row_no,col_no,seat_type').eq('bus_layout_id', active['id']);
        for (final s in seats) {
          d.cells[cellKey(s['row_no'] as int, s['col_no'] as int)] = SeatCell(kind: SeatKind.passenger, sleeper: s['seat_type'] == 'sleeper');
        }
        d.capacity = seats.length;
        d.rows = seats.fold<int>(0, (m, s) => (s['row_no'] as int) > m ? s['row_no'] as int : m);
        d.generatedSignature = d.signature;
      }
      d.step = 0;
      return d;
    }
    return SeatLayoutDraft(capacity: fallbackCapacity);
  }

  @override
  Future<void> saveDraft(String busId, SeatLayoutDraft d) async {
    final json = d.toJson(draft: true);
    final existing = await _draftRow(busId);
    if (existing != null) {
      await _db.from('bus_layouts').update({'layout_json': json}).eq('id', existing['id']);
    } else {
      await _db.from('bus_layouts').insert({
        'bus_id': busId,
        'name': 'Draft layout',
        'deck_count': 1,
        'layout_json': json,
        'is_active': false,
        'version': 0,
      });
    }
  }

  @override
  Future<void> save(String busId, SeatLayoutDraft d) async {
    final labels = computeLabels(d.cells, d.numbering, manualLabels: d.manualLabels);
    final previous = await _db
        .from('bus_layouts')
        .select('id,version')
        .eq('bus_id', busId)
        .eq('is_active', true)
        .maybeSingle();
    final versions = await _db.from('bus_layouts').select('version').eq('bus_id', busId);
    final nextVersion = versions.fold<int>(0, (m, r) => (r['version'] as int) > m ? r['version'] as int : m) + 1;

    final draft = await _draftRow(busId);
    final json = d.toJson();
    String layoutId;
    if (draft != null) {
      layoutId = draft['id'] as String;
      await _db.from('bus_layouts').update({'layout_json': json, 'version': nextVersion, 'name': 'Layout v$nextVersion'}).eq('id', layoutId);
    } else {
      final row = await _db
          .from('bus_layouts')
          .insert({'bus_id': busId, 'name': 'Layout v$nextVersion', 'deck_count': 1, 'layout_json': json, 'is_active': false, 'version': nextVersion})
          .select()
          .single();
      layoutId = row['id'] as String;
    }

    try {
      // Replace any seats left from a previous failed attempt on this row.
      await _db.from('seats').delete().eq('bus_layout_id', layoutId);
      final seatRows = <Map<String, dynamic>>[];
      d.cells.forEach((key, cell) {
        if (cell.kind != SeatKind.passenger) return;
        final p = key.split(',');
        seatRows.add({
          'bus_layout_id': layoutId,
          'seat_code': labels[key],
          'deck': 1,
          'row_no': int.parse(p[0]),
          'col_no': int.parse(p[1]),
          'seat_type': cell.sleeper ? 'sleeper' : 'seater',
        });
      });
      await _db.from('seats').insert(seatRows);

      // Swap active layout last so a failure above leaves the old one live.
      if (previous != null) await _db.from('bus_layouts').update({'is_active': false}).eq('id', previous['id']);
      try {
        await _db.from('bus_layouts').update({'is_active': true}).eq('id', layoutId);
      } catch (_) {
        if (previous != null) await _db.from('bus_layouts').update({'is_active': true}).eq('id', previous['id']);
        rethrow;
      }
      await _db.from('buses').update({'total_seats': seatRows.length}).eq('id', busId);
    } catch (_) {
      await _db.from('seats').delete().eq('bus_layout_id', layoutId);
      rethrow;
    }
  }
}
