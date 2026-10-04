import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase_providers.dart';
import 'seat_layout_model.dart';
import 'seat_layout_repository.dart';
import 'validation.dart';
import 'wizard_steps.dart';

/// Five-step guided seat layout setup. Only the current step's controls are
/// shown; Back/Continue are pinned to the bottom. The draft lives here so
/// moving between steps never loses configuration, and is also persisted as
/// a draft layout for "Save & continue later".
class SeatLayoutWizardScreen extends ConsumerStatefulWidget {
  const SeatLayoutWizardScreen({super.key, required this.busId, this.initialCapacity = 36, this.store});

  final String busId;
  final int initialCapacity;

  /// Overrides the Supabase-backed store (demo and tests).
  final SeatLayoutStore? store;

  @override
  ConsumerState<SeatLayoutWizardScreen> createState() => _SeatLayoutWizardScreenState();
}

class _SeatLayoutWizardScreenState extends ConsumerState<SeatLayoutWizardScreen> {
  static const _titles = ['Capacity', 'Arrangement', 'Seat map', 'Numbering', 'Review'];

  SeatLayoutDraft? _draft;
  bool _saving = false;
  String? _error;

  SeatLayoutStore get _repo => widget.store ?? SeatLayoutRepository(ref.read(supabaseProvider));

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await _repo.load(widget.busId, fallbackCapacity: widget.initialCapacity);
      if (mounted) setState(() => _draft = d);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load layout: $e');
    }
  }

  void _refresh() => setState(() {});

  bool _canContinue(SeatLayoutDraft d) => switch (d.step) {
        0 => validateCapacity(d) == null,
        2 => d.configured > 0,
        _ => true,
      };

  Future<void> _persistDraft() async {
    final d = _draft;
    if (d == null) return;
    try {
      await _repo.saveDraft(widget.busId, d);
    } catch (_) {
      // Draft saving is best-effort between steps; explicit saves surface errors.
    }
  }

  void _goTo(int step) {
    final d = _draft!;
    setState(() {
      d.step = step;
      // Entering the seat map: build the grid from steps 1–2 unless the user
      // already edited a grid generated from the same inputs.
      if (step == 2 && (d.cells.isEmpty || d.generatedSignature != d.signature)) d.generateGrid();
    });
    _persistDraft();
  }

  Future<void> _saveForLater() async {
    setState(() => _saving = true);
    try {
      await _repo.saveDraft(widget.busId, _draft!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Draft saved')));
      Navigator.of(context).pop(false);
    } catch (e) {
      setState(() => _error = 'Could not save draft: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _finish() async {
    final d = _draft!;
    if (validateLayout(d).any((i) => i.blocking)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _repo.save(widget.busId, d);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Could not save layout: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _draft;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Seat layout')),
        body: _error != null ? AppErrorState(message: _error!, onRetry: _load) : const AppLoadingState(),
      );
    }

    final isLast = d.step == _titles.length - 1;
    final blocked = isLast && validateLayout(d).any((i) => i.blocking);

    final body = switch (d.step) {
      0 => CapacityStep(draft: d, onChanged: _refresh),
      1 => ArrangementStep(draft: d, onChanged: _refresh),
      2 => SeatMapStep(draft: d, onChanged: _refresh),
      3 => NumberingStep(draft: d, onChanged: _refresh),
      _ => ReviewStep(draft: d),
    };

    return PopScope(
      canPop: d.step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goTo(d.step - 1);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Seat layout'),
          actions: [TextButton(onPressed: _saving ? null : _saveForLater, child: const Text('Save & later'))],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.xs),
                child: AppStepIndicator(titles: _titles, current: d.step, onStepTap: _goTo),
              ),
              Expanded(child: body),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                  child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
                ),
                child: Row(
                  children: [
                    if (d.step > 0) ...[
                      Expanded(
                        child: AppButton(label: 'Back', variant: AppButtonVariant.outline, onPressed: _saving ? null : () => _goTo(d.step - 1)),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    Expanded(
                      flex: 2,
                      child: AppButton(
                        label: isLast ? 'Save layout' : 'Continue',
                        loading: _saving,
                        onPressed: (_saving || blocked || !_canContinue(d)) ? null : (isLast ? _finish : () => _goTo(d.step + 1)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
