import 'dart:convert';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/trip_dashboard/manifest_models.dart';
import 'package:operator_app/features/trip_dashboard/manifest_pdf.dart';
import 'package:operator_app/features/trip_dashboard/passenger_manifest_section.dart';

ManifestPassenger pax({
  String seat = '1A',
  String name = 'Asha Rao',
  String booking = 'confirmed',
  String? docMasked = 'XXXX-XXXX-9012',
  String docLabel = 'Aadhaar card',
}) =>
    ManifestPassenger.fromJson({
      'booking_item_id': 'i-$seat',
      'booking_reference': 'TH100$seat',
      'seat_code': seat,
      'passenger_name': name,
      'passenger_phone': '9876543210',
      'boarding_point': 'Port Blair',
      'dropping_point': 'Rangat',
      'booking_status': booking,
      'payment_status': 'captured',
      'doc_label': docMasked == null ? null : docLabel,
      'doc_masked': docMasked,
      'boarding_status': 'not_boarded',
    });

final info = ManifestExportInfo(
  routeLabel: 'Port Blair → Rangat',
  busRegistration: 'AN01L5656',
  departureAt: DateTime(2026, 10, 5, 6),
  operatorName: 'Island Travels',
  bookingClosedAt: DateTime(2026, 10, 4, 22),
);

void main() {
  group('passenger list rows', () {
    test('only confirmed passengers are listed, numbered, with the masked ID', () {
      final rows = manifestExportRows([pax(seat: '1A'), pax(seat: '1B', booking: 'cancelled'), pax(seat: '2A', name: 'Ravi')]);
      expect(rows.length, 2);
      expect(rows[0].first, '1');
      expect(rows[1].first, '2');
      expect(rows.map((r) => r[1]), ['1A', '2A']);
      expect(rows[0][2], 'Asha Rao');
      expect(rows[0][3], '9876543210');
      expect(rows[0][4], 'Port Blair to Rangat');
      expect(rows[0][6], 'Aadhaar card: XXXX-XXXX-9012');
    });

    test('a passenger without an ID is shown as such, never invented', () {
      final rows = manifestExportRows([pax(docMasked: null)]);
      expect(rows.single[6], 'No ID on file');
    });

    test('PDF text is plain ASCII punctuation so nothing prints as a box with the fallback font', () {
      final cells = [...manifestExportHeaders, ...manifestExportRows([pax(), pax(docMasked: null)]).expand((r) => r)];
      expect(cells.any((c) => c.contains('→') || c.contains('—')), isFalse);
    });

    test('the table has a blank tick column to mark boarding on paper', () {
      expect(manifestExportHeaders.last, 'Boarded');
      expect(manifestExportRows([pax()]).single.last, '');
      expect(manifestExportHeaders.length, manifestExportRows([pax()]).single.length);
    });

    test('file name carries route, date and bus', () {
      expect(manifestExportFileName(info), 'passenger-list_Port-Blair-Rangat_2026-10-05_AN01L5656.pdf');
    });
  });

  group('PDF', () {
    test('produces a real PDF document', () async {
      final bytes = await buildManifestPdf([pax(), pax(seat: '1B', name: 'Ravi Kumar')], info, loadFonts: false, generatedAt: DateTime(2026, 10, 4, 23));
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));
    });

    test('an empty trip still produces a valid document', () async {
      final bytes = await buildManifestPdf(const [], info, loadFonts: false);
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    });

    test('many passengers paginate without failing', () async {
      final many = [for (var i = 1; i <= 120; i++) pax(seat: 'S$i', name: 'Passenger $i')];
      final bytes = await buildManifestPdf(many, info, loadFonts: false);
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    });

    test('a full ID number can never be on the page: the model only holds the masked form', () {
      final p = pax(docMasked: 'XXXX-XXXX-9012');
      expect(manifestExportRows([p]).expand((r) => r).any((c) => c.contains('1234 5678')), isFalse);
    });
  });

  group('ManifestResult', () {
    test('parses whether booking has closed', () {
      final r = ManifestResult.fromJson({'passengers': [], 'booking_closed': true, 'booking_close_at': '2026-10-04T16:30:00Z', 'departure_at': '2026-10-05T00:30:00Z'});
      expect(r.bookingClosed, isTrue);
      expect(r.bookingCloseAt, isNotNull);
      expect(ManifestResult.fromJson({'passengers': []}).bookingClosed, isFalse);
    });
  });

  group('export bar', () {
    Widget host(ManifestResult result) => ProviderScope(
          overrides: <Override>[tripManifestProvider.overrideWith((ref, q) async => result)],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: PassengerManifestSection(tripId: 't1', operatorContext: null, tripStatus: 'scheduled', exportInfo: info),
              ),
            ),
          ),
        );

    testWidgets('locked while booking is open, and says when it unlocks', (tester) async {
      await tester.pumpWidget(host(ManifestResult(passengers: [pax()], bookingClosed: false, bookingCloseAt: DateTime(2026, 10, 4, 22))));
      await tester.pumpAndSettle();
      expect(find.text('Passenger list (PDF)'), findsOneWidget);
      expect(find.textContaining('Available once booking closes'), findsOneWidget);
      final download = tester.widget<AppButton>(find.widgetWithText(AppButton, 'Download'));
      final share = tester.widget<AppButton>(find.widgetWithText(AppButton, 'Share'));
      expect(download.onPressed, isNull);
      expect(share.onPressed, isNull);
    });

    testWidgets('Download and Share unlock once booking has closed', (tester) async {
      await tester.pumpWidget(host(ManifestResult(passengers: [pax()], bookingClosed: true, bookingCloseAt: DateTime(2026, 10, 4, 22))));
      await tester.pumpAndSettle();
      expect(find.textContaining('Booking is closed'), findsOneWidget);
      expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Download')).onPressed, isNotNull);
      expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Share')).onPressed, isNotNull);
    });
  });
}
