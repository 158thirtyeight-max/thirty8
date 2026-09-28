import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/supabase_providers.dart';
import 'city.dart';

/// Full-screen city search — calls the search_cities RPC (trigram-ranked)
/// on every keystroke, debounced.
class CityPickerScreen extends ConsumerStatefulWidget {
  const CityPickerScreen({super.key, required this.title});

  final String title;

  @override
  ConsumerState<CityPickerScreen> createState() => _CityPickerScreenState();
}

class _CityPickerScreenState extends ConsumerState<CityPickerScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<City> _results = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(query));
  }

  Future<void> _search(String query) async {
    setState(() => _loading = true);
    try {
      final res = await ref.read(supabaseProvider).rpc('search_cities', params: {
        'p_query': query,
        'p_limit': 20,
      });
      if (!mounted) return;
      setState(() {
        _results = (res as List).map((e) => City.fromJson(e as Map<String, dynamic>)).toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: widget.title,
            border: InputBorder.none,
          ),
        ),
      ),
      body: _loading
          ? const Center(child: AppLoadingState())
          : ListView.separated(
              itemCount: _results.length,
              separatorBuilder: (a, b) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final city = _results[index];
                return AppListItem(
                  leading: const Icon(Icons.location_on_outlined),
                  title: city.name,
                  subtitle: city.state,
                  onTap: () => Navigator.of(context).pop(city),
                );
              },
            ),
    );
  }
}
