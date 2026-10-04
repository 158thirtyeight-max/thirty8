// Runs the seat layout wizard with in-memory data — no Supabase needed.
//   flutter run -d chrome -t demo/seat_layout_demo.dart
import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:operator_app/features/bus_ops/seat_layout/seat_layout_model.dart';
import 'package:operator_app/features/bus_ops/seat_layout/seat_layout_repository.dart';
import 'package:operator_app/features/bus_ops/seat_layout/seat_layout_wizard_screen.dart';

class _MemoryStore implements SeatLayoutStore {
  SeatLayoutDraft? draft;
  SeatLayoutDraft? saved;

  SeatLayoutDraft _copy(SeatLayoutDraft d) => SeatLayoutDraft.fromJson(d.toJson(draft: true));

  @override
  Future<SeatLayoutDraft> load(String busId, {required int fallbackCapacity}) async =>
      _copy(draft ?? saved ?? SeatLayoutDraft(capacity: fallbackCapacity));

  @override
  Future<void> saveDraft(String busId, SeatLayoutDraft d) async => draft = _copy(d);

  @override
  Future<void> save(String busId, SeatLayoutDraft d) async {
    saved = _copy(d);
    draft = null;
  }
}

void main() => runApp(const ProviderScope(child: _DemoApp()));

class _DemoApp extends StatelessWidget {
  const _DemoApp();

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Seat layout wizard demo',
        theme: AppTheme.dark(),
        debugShowCheckedModeBanner: false,
        home: const _Home(),
      );
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _store = _MemoryStore();
  String _status = 'No layout saved yet';

  Future<void> _open() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SeatLayoutWizardScreen(busId: 'demo-bus', initialCapacity: 36, store: _store)),
    );
    final s = _store.saved;
    setState(() {
      if (result == true && s != null) {
        _status = 'Saved: ${s.countKind(SeatKind.passenger)} passenger seats, ${s.arrangement.label}, ${s.numbering.name} numbering';
      } else if (_store.draft != null) {
        _status = 'Draft saved — reopen to resume at step ${_store.draft!.step + 1}';
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Bus MOJO · Seat layout demo')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_status, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              AppButton(label: 'Open seat layout setup', expand: true, onPressed: _open),
            ],
          ),
        ),
      );
}
