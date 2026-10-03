import 'package:flutter/material.dart';

/// One selectable stop option. [id] is the value stored in the database
/// (bus_service_stops.stop_purposes / meal_types / refreshment_types / facilities).
class StopOption {
  const StopOption(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;
}

/// Stop purposes & passenger facilities shared by the operator app (editing)
/// and the customer app (journey timeline). Ids must match the CHECK
/// constraints in supabase/migrations/20260927000100_service_stops.sql.
class StopCatalog {
  StopCatalog._();

  static const mealBreak = 'meal_break';
  static const teaRefreshment = 'tea_refreshment';

  static const purposes = <StopOption>[
    StopOption(mealBreak, 'Meal Break', Icons.restaurant),
    StopOption(teaRefreshment, 'Tea / Refreshment', Icons.local_cafe),
    StopOption('toilet_break', 'Toilet Break', Icons.wc),
    StopOption('rest_break', 'Rest Break', Icons.weekend),
    StopOption('ferry_transfer', 'Ferry Transfer', Icons.directions_boat),
    StopOption('passenger_transfer', 'Passenger Transfer', Icons.swap_horiz),
    StopOption('other', 'Other', Icons.more_horiz),
  ];

  static const mealTypes = <StopOption>[
    StopOption('breakfast', 'Breakfast', Icons.free_breakfast),
    StopOption('lunch', 'Lunch', Icons.lunch_dining),
    StopOption('dinner', 'Dinner', Icons.dinner_dining),
  ];

  static const refreshmentTypes = <StopOption>[
    StopOption('tea', 'Tea', Icons.emoji_food_beverage),
    StopOption('coffee', 'Coffee', Icons.coffee),
    StopOption('snacks', 'Snacks', Icons.cookie),
  ];

  static const facilities = <StopOption>[
    StopOption('restaurant_food', 'Restaurant / Food', Icons.restaurant_menu),
    StopOption('toilet', 'Toilet', Icons.wc),
    StopOption('drinking_water', 'Drinking Water', Icons.water_drop),
    StopOption('waiting_area', 'Waiting Area', Icons.chair),
    StopOption('refreshment_shop', 'Refreshment Shop', Icons.storefront),
  ];

  static String _label(List<StopOption> options, String id) =>
      options.firstWhere((o) => o.id == id, orElse: () => StopOption(id, id, Icons.circle)).label;

  /// Customer-facing labels for a stop's purposes, in catalog order.
  /// "Other" is operator bookkeeping and has no customer label.
  ///
  /// Meal Break + meal types reads naturally: lunch -> "Lunch Break",
  /// breakfast -> "Breakfast Stop", dinner -> "Dinner Break"; with no meal
  /// type chosen it stays "Meal Break". Tea / Refreshment -> "Tea & Refreshment".
  static List<String> customerLabels({
    required List<String> purposes,
    List<String> mealTypes = const [],
    List<String> refreshmentTypes = const [],
  }) {
    final labels = <String>[];
    for (final p in StopCatalog.purposes.map((o) => o.id).where(purposes.contains)) {
      switch (p) {
        case mealBreak:
          final meals = StopCatalog.mealTypes.map((o) => o.id).where(mealTypes.contains).toList();
          if (meals.isEmpty) {
            labels.add('Meal Break');
          } else {
            labels.addAll(meals.map((m) => m == 'breakfast' ? 'Breakfast Stop' : '${_label(StopCatalog.mealTypes, m)} Break'));
          }
        case teaRefreshment:
          labels.add('Tea & Refreshment');
        case 'other':
          break;
        default:
          labels.add(_label(StopCatalog.purposes, p));
      }
    }
    return labels;
  }

  /// Facility labels in catalog order, e.g. ["Toilet", "Drinking Water"].
  static List<String> facilityLabels(List<String> ids) =>
      StopCatalog.facilities.where((o) => ids.contains(o.id)).map((o) => o.label).toList();
}
