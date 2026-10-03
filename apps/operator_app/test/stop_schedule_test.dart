import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/bus_ops/stops/stop_schedule.dart';

StopDraft stop(int arrival, {int duration = 2, List<String> purposes = const [], List<String> meals = const []}) =>
    StopDraft(locationCityId: 'c$arrival', locationName: 'Stop $arrival', arrivalOffset: arrival, durationMinutes: duration, purposes: purposes, mealTypes: meals);

void main() {
  group('departure = arrival + duration', () {
    test('regular stop, default 2 min', () => expect(stop(120).departureOffset, 122));
    test('lunch stop with 30 min', () => expect(stop(120, duration: 30, purposes: ['meal_break'], meals: ['lunch']).departureOffset, 150));
    test('purposes never change timing', () {
      final plain = stop(120, duration: 30);
      final withPurposes = stop(120, duration: 30, purposes: ['meal_break', 'ferry_transfer', 'toilet_break']);
      expect(withPurposes.departureOffset, plain.departureOffset);
    });
  });

  group('arrivalWindow', () {
    test('first stop sits between origin and next stop', () {
      final w = arrivalWindow(prevDeparture: 0, nextArrival: 300, totalMinutes: 600, durationMinutes: 30);
      expect((w.min, w.max), (1, 269));
    });
    test('last stop is bounded by the destination', () {
      final w = arrivalWindow(prevDeparture: 150, nextArrival: null, totalMinutes: 600, durationMinutes: 10);
      expect((w.min, w.max), (151, 589));
    });
    test('longer duration shrinks the window; too tight is empty', () {
      expect(arrivalWindow(prevDeparture: 100, nextArrival: 110, totalMinutes: 600, durationMinutes: 15).isEmpty, isTrue);
    });
    test('maxDuration', () => expect(maxDuration(arrivalOffset: 120, nextArrival: 150, totalMinutes: 600), 29));
  });

  group('validateStops', () {
    test('valid list', () => expect(validateStops([stop(120, duration: 30), stop(300, duration: 10)], 600), isNull));
    test('next stop must arrive after previous departs', () => expect(validateStops([stop(120, duration: 30), stop(150)], 600), contains('Stop 2')));
    test('must depart before destination', () => expect(validateStops([stop(590, duration: 15)], 600), contains('destination')));
    test('needs pickup or drop', () {
      final s = stop(120)
        ..allowsPickup = false
        ..allowsDrop = false;
      expect(validateStops([s], 600), contains('pickup'));
    });
  });

  group('overnight labels', () {
    // origin departs 20:00 -> minute 1200
    test('same day', () => expect(clockLabel(1200, 120), '22:00'));
    test('rolls to next day', () => expect(clockLabel(1200, 300), '01:00 (+1 day)'));
    test('exactly midnight', () => expect(clockLabel(1200, 240), '00:00 (+1 day)'));
    test('multi-day', () => expect(clockLabel(600, 3000), '12:00 (+2 days)'));
    test('durationLabel', () {
      expect(durationLabel(30), '30 min');
      expect(durationLabel(60), '1 h');
      expect(durationLabel(75), '1 h 15 min');
    });
  });

  group('purposes', () {
    test('removing Meal Break clears meal types', () {
      final s = stop(120, purposes: ['meal_break', 'tea_refreshment'], meals: ['lunch'])..refreshmentTypes.add('tea');
      s.purposes.remove('meal_break');
      s.pruneSubOptions();
      expect(s.mealTypes, isEmpty);
      expect(s.refreshmentTypes, {'tea'});
    });
    test('rpc payload uses structured arrays', () {
      final json = stop(120, duration: 30, purposes: ['meal_break'], meals: ['lunch']).toRpc();
      expect(json['stop_purposes'], ['meal_break']);
      expect(json['meal_types'], ['lunch']);
      expect(json['refreshment_types'], isEmpty);
      expect(json.containsKey('departure_offset_minutes'), isFalse);
    });
    test('save and reopen round-trips; legacy rows read as empty', () {
      final original = stop(300, duration: 10, purposes: ['tea_refreshment', 'toilet_break']);
      original.refreshmentTypes.addAll(['tea', 'snacks']);
      original.facilities.add('toilet');
      final row = {...original.toRpc(), 'cities': {'name': 'Rangat'}};
      final reopened = StopDraft.fromRow(row);
      expect(reopened.purposes, original.purposes);
      expect(reopened.refreshmentTypes, original.refreshmentTypes);
      expect(reopened.facilities, {'toilet'});
      expect(reopened.locationName, 'Rangat');
      final legacy = StopDraft.fromRow({'location_city_id': 'x', 'arrival_offset_minutes': 60});
      expect(legacy.purposes, isEmpty);
      expect(legacy.facilities, isEmpty);
      expect(legacy.durationMinutes, 2);
    });
  });

  group('customer labels', () {
    test('regular stop has none', () => expect(StopCatalog.customerLabels(purposes: const []), isEmpty));
    test('meals', () {
      expect(StopCatalog.customerLabels(purposes: ['meal_break'], mealTypes: ['lunch']), ['Lunch Break']);
      expect(StopCatalog.customerLabels(purposes: ['meal_break'], mealTypes: ['breakfast']), ['Breakfast Stop']);
      expect(StopCatalog.customerLabels(purposes: ['meal_break']), ['Meal Break']);
    });
    test('tea and toilet', () => expect(StopCatalog.customerLabels(purposes: ['toilet_break', 'tea_refreshment']), ['Tea & Refreshment', 'Toilet Break']));
    test('ferry transfer; other is internal', () => expect(StopCatalog.customerLabels(purposes: ['ferry_transfer', 'other']), ['Ferry Transfer']));
    test('facilities', () => expect(StopCatalog.facilityLabels(['drinking_water', 'toilet']), ['Toilet', 'Drinking Water']));
  });
}
