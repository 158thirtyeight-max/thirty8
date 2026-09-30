import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'fare_model.dart';
import 'fleet_providers.dart';
import 'stage_seat_layout_screen.dart';

class _RouteFareRow {
  _RouteFareRow({this.fromId, this.toId, required this.controllers});
  String? fromId;
  String? toId;
  final Map<String, TextEditingController> controllers; // by FareClass.key
}

class _ChargeRow {
  _ChargeRow({String name = '', this.isPercent = false, String value = ''})
      : name = TextEditingController(text: name),
        value = TextEditingController(text: value);
  final TextEditingController name;
  final TextEditingController value;
  bool isPercent;
}

/// Stage E — fares. Base fare per seat class, optional premium-seat fares,
/// boarding-to-destination fares, and extra charges. Prices are never
/// hard-coded per bus: the fare engine on the server resolves the most
/// specific rule for every seat and journey.
class StageFareScreen extends ConsumerStatefulWidget {
  const StageFareScreen({super.key, required this.operatorId, required this.bus});

  final String operatorId;
  final Map<String, dynamic> bus;

  @override
  ConsumerState<StageFareScreen> createState() => _StageFareScreenState();
}

class _StageFareScreenState extends ConsumerState<StageFareScreen> {
  bool _loaded = false;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  List<String> _serverErrors = const [];

  List<FareClass> _classes = const [];
  bool _hasPremium = false;
  final Map<String, TextEditingController> _base = {};
  final Map<String, TextEditingController> _premium = {};
  final List<_RouteFareRow> _routeFares = [];
  final List<_ChargeRow> _charges = [];

  bool get _editable {
    final lifecycle = widget.bus['lifecycle_status'] as String?;
    return widget.bus['is_legacy'] == true ||
        const ['draft', 'changes_requested', 'approved', 'active'].contains(lifecycle);
  }

  @override
  void dispose() {
    for (final c in [..._base.values, ..._premium.values]) {
      c.dispose();
    }
    for (final r in _routeFares) {
      for (final c in r.controllers.values) {
        c.dispose();
      }
    }
    for (final c in _charges) {
      c.name.dispose();
      c.value.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctl([String text = '']) {
    final c = TextEditingController(text: text);
    c.addListener(() {
      if (mounted) setState(() => _dirty = true);
    });
    return c;
  }

  String _rupeesText(int cents) => cents % 100 == 0 ? '${cents ~/ 100}' : (cents / 100).toStringAsFixed(2);

  void _load(Map<String, dynamic> layout, Map<String, dynamic> fares) {
    if (_loaded) return;
    _loaded = true;
    final seats = List<Map<String, dynamic>>.from(layout['seats'] as List);
    final derived = fareClassesFromSeats(seats);
    _classes = derived.classes;
    _hasPremium = derived.hasPremium;

    final rules = [for (final r in List<Map<String, dynamic>>.from(fares['rules'] as List)) FareRule.fromRow(r)];
    for (final c in _classes) {
      final base = rules.where((r) =>
          r.seatType == c.seatType && r.fromPointId == null && r.toPointId == null && r.category == null && (r.berth == null || r.berth == c.berth));
      _base[c.key] = _ctl(base.isEmpty ? '' : _rupeesText(base.first.cents));
      if (_hasPremium) {
        final prem = rules.where((r) =>
            r.seatType == c.seatType && r.fromPointId == null && r.toPointId == null && r.category == 'premium' && (r.berth == null || r.berth == c.berth));
        _premium[c.key] = _ctl(prem.isEmpty ? '' : _rupeesText(prem.first.cents));
      }
    }

    final grouped = <String, _RouteFareRow>{};
    for (final r in rules.where((r) => (r.fromPointId != null || r.toPointId != null) && r.category == null)) {
      final key = '${r.fromPointId}|${r.toPointId}';
      final row = grouped.putIfAbsent(
        key,
        () => _RouteFareRow(fromId: r.fromPointId, toId: r.toPointId, controllers: {for (final c in _classes) c.key: _ctl()}),
      );
      final cls = _classes.where((c) => c.seatType == r.seatType && (r.berth == null || r.berth == c.berth));
      for (final c in cls) {
        row.controllers[c.key]!.text = _rupeesText(r.cents);
      }
    }
    _routeFares.addAll(grouped.values);

    for (final c in List<Map<String, dynamic>>.from(fares['charges'] as List)) {
      final ch = FareCharge.fromRow(c);
      _charges.add(_ChargeRow(name: ch.name, isPercent: ch.isPercent, value: ch.isPercent ? ch.value.toString() : _rupeesText((ch.value * 100).round())));
    }
    _dirty = false;
  }

  List<FareRule> _collectRules() {
    final rules = <FareRule>[];
    for (final c in _classes) {
      final base = parseRupees(_base[c.key]?.text);
      if (base != null) rules.add(FareRule(seatType: c.seatType, berth: c.berth, cents: base));
      if (_hasPremium) {
        final p = parseRupees(_premium[c.key]?.text);
        if (p != null) rules.add(FareRule(seatType: c.seatType, berth: c.berth, category: 'premium', cents: p));
      }
      for (final r in _routeFares) {
        final v = parseRupees(r.controllers[c.key]?.text);
        if (v != null && (r.fromId != null || r.toId != null)) {
          rules.add(FareRule(seatType: c.seatType, berth: c.berth, fromPointId: r.fromId, toPointId: r.toId, cents: v));
        }
      }
    }
    return rules;
  }

  List<FareCharge> _collectCharges() {
    final out = <FareCharge>[];
    for (final c in _charges) {
      final raw = c.value.text.trim();
      final v = c.isPercent ? double.tryParse(raw) : (parseRupees(raw)?.toDouble() ?? double.nan) / 100;
      if (v == null || v.isNaN) continue;
      out.add(FareCharge(name: c.name.text, isPercent: c.isPercent, value: v));
    }
    return out;
  }

  Future<void> _save() async {
    // Reject unparsable amounts instead of silently dropping them.
    for (final c in _classes) {
      for (final t in [_base[c.key]?.text, _premium[c.key]?.text, ..._routeFares.map((r) => r.controllers[c.key]?.text)]) {
        if (t != null && t.trim().isNotEmpty && parseRupees(t) == null) {
          setState(() => _serverErrors = ['"$t" is not a valid amount (use rupees with up to 2 decimals)']);
          return;
        }
      }
    }
    final rules = _collectRules();
    final charges = _collectCharges();
    final errors = validateFares(classes: _classes, rules: rules, charges: charges);
    if (errors.isNotEmpty) {
      setState(() => _serverErrors = errors);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _serverErrors = const [];
    });
    try {
      final res = await ref.read(supabaseProvider).rpc('save_bus_fares', params: {
        'p_bus_id': widget.bus['id'],
        'p_rules': [for (final r in rules) r.toJson()],
        'p_charges': [for (final c in charges) c.toJson()],
      });
      final map = Map<String, dynamic>.from(res as Map);
      ref.invalidate(busFaresProvider(widget.bus['id'] as String));
      setState(() {
        _dirty = false;
        _serverErrors = List<String>.from(map['errors'] as List);
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_serverErrors.isEmpty ? 'Fares saved.' : 'Saved — but the fares still have issues to fix.'),
        ));
      }
    } catch (e) {
      setState(() => _error = e.toString().contains('route')
          ? 'Configure the route before setting fares.'
          : 'Could not save the fares. Please check the amounts and try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busId = widget.bus['id'] as String;
    final layoutAsync = ref.watch(busLayoutProvider(busId));
    final faresAsync = ref.watch(busFaresProvider(busId));
    final routeAsync = ref.watch(busRouteProvider(busId));

    return Scaffold(
      appBar: AppBar(title: const Text('Fares')),
      body: SafeArea(
        child: Builder(builder: (context) {
          if (layoutAsync.hasError || faresAsync.hasError || routeAsync.hasError) {
            return AppErrorState(
              message: 'Could not load fares.',
              onRetry: () {
                ref.invalidate(busLayoutProvider(busId));
                ref.invalidate(busFaresProvider(busId));
                ref.invalidate(busRouteProvider(busId));
              },
            );
          }
          if (!layoutAsync.hasValue || !faresAsync.hasValue || !routeAsync.hasValue) return const AppLoadingState();
          final route = routeAsync.requireValue;
          if (route['service'] == null) {
            return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Set up the route first (Stage D), then come back to set fares.')));
          }
          _load(layoutAsync.requireValue, faresAsync.requireValue);
          if (_classes.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Configure the seat layout first (Stage C) so we know which seat types need a fare.')));
          }
          return _form(context, route);
        }),
      ),
    );
  }

  Widget _form(BuildContext context, Map<String, dynamic> route) {
    final theme = Theme.of(context);
    final edit = _editable && !_saving;
    final boarding = List<Map<String, dynamic>>.from(route['boarding'] as List);
    final dropping = List<Map<String, dynamic>>.from(route['dropping'] as List);

    Widget amount(TextEditingController c, String label) => AppTextField(
          controller: c,
          label: label,
          enabled: edit,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          prefixIcon: Icons.currency_rupee,
        );

    DropdownButtonFormField<String?> pointDropdown(String label, String? value, List<Map<String, dynamic>> pts, ValueChanged<String?> onChanged) {
      return DropdownButtonFormField<String?>(
        initialValue: pts.any((p) => p['id'] == value) ? value : null,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          DropdownMenuItem<String?>(value: null, child: Text(label == 'From' ? 'Any boarding point' : 'Any destination')),
          for (final p in pts) DropdownMenuItem<String?>(value: p['id'] as String, child: Text(p['name'] as String, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: edit ? onChanged : null,
      );
    }

    final rules = _collectRules();
    final charges = _collectCharges();
    final previewClass = _classes.first;
    final pairs = <(Map<String, dynamic>, Map<String, dynamic>)>[
      for (final b in boarding)
        for (final d in dropping)
          if ((d['sequence_no'] as int) > (b['sequence_no'] as int)) (b, d),
    ];

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        if (!_editable) const Padding(padding: EdgeInsets.only(bottom: AppSpacing.sm), child: Text('Fares are locked while the bus is under review or suspended.')),
        Text('Base fare', style: theme.textTheme.titleMedium),
        Text('The standard price when no more specific fare applies. Amounts are in rupees per seat.', style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        for (final c in _classes)
          Padding(padding: const EdgeInsets.only(bottom: AppSpacing.sm), child: amount(_base[c.key]!, c.label)),
        if (_hasPremium) ...[
          const SizedBox(height: AppSpacing.sm),
          Text('Premium seats (optional)', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          for (final c in _classes)
            Padding(padding: const EdgeInsets.only(bottom: AppSpacing.sm), child: amount(_premium[c.key]!, '${c.label} · premium')),
        ],
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(child: Text('Stop-to-stop fares', style: theme.textTheme.titleMedium)),
            if (edit)
              TextButton.icon(
                onPressed: () => setState(() {
                  _dirty = true;
                  _routeFares.add(_RouteFareRow(controllers: {for (final c in _classes) c.key: _ctl()}));
                }),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
          ],
        ),
        Text('Different prices for particular boarding and destination stops. Leave "any" to match all.', style: theme.textTheme.bodySmall),
        const SizedBox(height: AppSpacing.sm),
        for (var i = 0; i < _routeFares.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: AppCard(
              child: Column(
                children: [
                  pointDropdown('From', _routeFares[i].fromId, boarding, (v) => setState(() { _routeFares[i].fromId = v; _dirty = true; })),
                  const SizedBox(height: AppSpacing.xs),
                  pointDropdown('To', _routeFares[i].toId, dropping, (v) => setState(() { _routeFares[i].toId = v; _dirty = true; })),
                  const SizedBox(height: AppSpacing.xs),
                  for (final c in _classes)
                    Padding(padding: const EdgeInsets.only(bottom: AppSpacing.xs), child: amount(_routeFares[i].controllers[c.key]!, c.label)),
                  if (edit)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(onPressed: () => setState(() { _dirty = true; _routeFares.removeAt(i); }), child: const Text('Remove')),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(child: Text('Other charges', style: theme.textTheme.titleMedium)),
            if (edit)
              TextButton.icon(
                onPressed: () => setState(() {
                  _dirty = true;
                  _charges.add(_ChargeRow());
                }),
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
          ],
        ),
        Text('Added to every seat fare, e.g. a convenience fee or tax.', style: theme.textTheme.bodySmall),
        for (var i = 0; i < _charges.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: AppCard(
              child: Column(
                children: [
                  AppTextField(controller: _charges[i].name, label: 'Charge name', enabled: edit, onChanged: (_) => setState(() => _dirty = true)),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Expanded(
                        child: AppTextField(
                          controller: _charges[i].value,
                          label: _charges[i].isPercent ? 'Percent' : 'Amount (₹)',
                          enabled: edit,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          onChanged: (_) => setState(() => _dirty = true),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      SegmentedButton<bool>(
                        segments: const [ButtonSegment(value: false, label: Text('₹')), ButtonSegment(value: true, label: Text('%'))],
                        selected: {_charges[i].isPercent},
                        onSelectionChanged: edit ? (s) => setState(() { _charges[i].isPercent = s.first; _dirty = true; }) : null,
                      ),
                    ],
                  ),
                  if (edit)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(onPressed: () => setState(() { _dirty = true; _charges.removeAt(i); }), child: const Text('Remove')),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Price preview · ${previewClass.label} (customer pays, incl. charges)', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              if (pairs.isEmpty)
                Text('Any journey: ${formatRupees(previewFare(rules: rules, charges: charges, seatType: previewClass.seatType, berth: previewClass.berth))}')
              else
                for (final p in pairs)
                  Text('${p.$1['name']} → ${p.$2['name']}: ${formatRupees(previewFare(
                    rules: rules,
                    charges: charges,
                    seatType: previewClass.seatType,
                    berth: previewClass.berth,
                    boardingId: p.$1['id'] as String,
                    droppingId: p.$2['id'] as String,
                  ))}'),
              const SizedBox(height: AppSpacing.xs),
              Text('The server calculates the final price the same way for search, seat selection and booking.', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
        if (_serverErrors.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          for (final e in _serverErrors)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error),
                const SizedBox(width: 4),
                Expanded(child: Text(e, style: TextStyle(color: theme.colorScheme.error))),
              ]),
            ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        if (_editable) ...[
          const SizedBox(height: AppSpacing.md),
          AppButton(label: 'Save fares', expand: true, loading: _saving, onPressed: (_saving || !_dirty) ? null : _save),
          AppButton(
            label: 'Save & continue later',
            variant: AppButtonVariant.ghost,
            expand: true,
            onPressed: _saving
                ? null
                : () async {
                    if (_dirty) await _save();
                    if (context.mounted && _serverErrors.isEmpty) Navigator.of(context).pop();
                  },
          ),
        ],
      ],
    );
  }
}
