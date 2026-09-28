import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../search/city.dart';
import '../search/city_picker_screen.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  City? _source;
  City? _destination;
  DateTime _date = DateTime.now();

  Future<void> _pickCity({required bool isSource}) async {
    final city = await Navigator.of(context).push<City>(
      MaterialPageRoute(
        builder: (_) => CityPickerScreen(title: isSource ? 'Leaving from' : 'Going to'),
      ),
    );
    if (city == null) return;
    setState(() {
      if (isSource) {
        _source = city;
      } else {
        _destination = city;
      }
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 120)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _swap() {
    setState(() {
      final tmp = _source;
      _source = _destination;
      _destination = tmp;
    });
  }

  void _search() {
    if (_source == null || _destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose where you’re leaving from and going to')),
      );
      return;
    }
    if (_source!.id == _destination!.id) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Source and destination can’t be the same')),
      );
      return;
    }
    context.push('/search-results', extra: {
      'source': _source,
      'destination': _destination,
      'date': _date,
    });
  }

  @override
  Widget build(BuildContext context) {
    final dateLabel = DateFormat('EEE, d MMM').format(_date);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Thirty8', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Where are you headed?', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 20),
          AppCard(
            child: Column(
              children: [
                _PickerRow(
                  icon: Icons.trip_origin,
                  label: _source?.name ?? 'Leaving from',
                  onTap: () => _pickCity(isSource: true),
                ),
                const Divider(height: 24),
                Stack(
                  alignment: Alignment.centerRight,
                  children: [
                    _PickerRow(
                      icon: Icons.location_on,
                      label: _destination?.name ?? 'Going to',
                      onTap: () => _pickCity(isSource: false),
                    ),
                    IconButton(
                      icon: const Icon(Icons.swap_vert),
                      onPressed: _swap,
                      tooltip: 'Swap',
                    ),
                  ],
                ),
                const Divider(height: 24),
                _PickerRow(
                  icon: Icons.calendar_today_outlined,
                  label: dateLabel,
                  onTap: _pickDate,
                ),
                const SizedBox(height: 16),
                AppButton(
                  label: 'Search buses',
                  onPressed: _search,
                  icon: Icons.search,
                  expand: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.smRadius,
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyLarge)),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}
