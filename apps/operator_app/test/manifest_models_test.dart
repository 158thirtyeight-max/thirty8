import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/trip_dashboard/manifest_models.dart';

Map<String, dynamic> row({
  String booking = 'confirmed',
  String payment = 'captured',
  String boarding = 'not_boarded',
  String? doc = 'XXXX-XXXX-9012',
  String? refund,
}) =>
    {
      'booking_item_id': 'i1',
      'booking_reference': 'TH-100',
      'seat_code': '1A',
      'passenger_name': 'Asha Rao',
      'passenger_phone': '9876543210',
      'boarding_point': 'Port Blair',
      'dropping_point': 'Rangat',
      'booking_status': booking,
      'payment_status': payment,
      'refund_status': refund,
      'doc_label': doc == null ? null : 'Aadhaar',
      'doc_masked': doc,
      'doc_verification': doc == null ? null : 'unverified',
      'boarding_status': boarding,
    };

void main() {
  group('ManifestPassenger', () {
    test('parses identity, phone, points and statuses', () {
      final p = ManifestPassenger.fromJson(row());
      expect(p.name, 'Asha Rao');
      expect(p.phone, '9876543210');
      expect(p.boardingPoint, 'Port Blair');
      expect(p.droppingPoint, 'Rangat');
      expect(p.bookingReference, 'TH-100');
      expect(p.boarding, BoardingStatus.notBoarded);
    });

    test('document is shown masked with its type, never as a full number', () {
      final p = ManifestPassenger.fromJson(row());
      expect(p.documentLine, 'Aadhaar: XXXX-XXXX-9012');
      expect(p.documentLine, isNot(contains('1234')));
    });

    test('no document on file', () {
      final p = ManifestPassenger.fromJson(row(doc: null));
      expect(p.hasDocument, isFalse);
      expect(p.documentLine, isNull);
    });
  });

  group('boarding rules in the UI mirror the server', () {
    test('paid + confirmed can be verified; verified can be confirmed', () {
      final p = ManifestPassenger.fromJson(row());
      expect(p.canVerify, isTrue);
      expect(p.canConfirmBoarding, isFalse, reason: 'must verify first');
      final v = ManifestPassenger.fromJson(row(boarding: 'verified'));
      expect(v.canConfirmBoarding, isTrue);
    });

    test('paid does not mean boarded', () {
      final p = ManifestPassenger.fromJson(row(payment: 'captured', boarding: 'not_boarded'));
      expect(p.boarding, isNot(BoardingStatus.boarded));
      expect(p.canConfirmBoarding, isFalse);
    });

    test('unpaid or unconfirmed bookings cannot be verified', () {
      expect(ManifestPassenger.fromJson(row(payment: 'pending')).canVerify, isFalse);
      expect(ManifestPassenger.fromJson(row(booking: 'payment_pending', payment: 'pending')).canVerify, isFalse);
      expect(ManifestPassenger.fromJson(row(booking: 'cancelled')).canVerify, isFalse);
    });

    test('a boarded passenger cannot be verified or reported again', () {
      final p = ManifestPassenger.fromJson(row(boarding: 'boarded'));
      expect(p.canVerify, isFalse);
      expect(p.canConfirmBoarding, isFalse);
      expect(p.canReportException, isFalse);
    });

    test('payment exceptions are flagged (pending refund or uncaptured payment)', () {
      expect(ManifestPassenger.fromJson(row(refund: 'pending')).hasPaymentException, isTrue);
      expect(ManifestPassenger.fromJson(row(payment: 'failed')).hasPaymentException, isTrue);
      expect(ManifestPassenger.fromJson(row()).hasPaymentException, isFalse);
    });
  });

  test('boarding status parsing and labels', () {
    expect(BoardingStatusX.parse('verified'), BoardingStatus.verified);
    expect(BoardingStatusX.parse('boarded'), BoardingStatus.boarded);
    expect(BoardingStatusX.parse('exception'), BoardingStatus.exception);
    expect(BoardingStatusX.parse(null), BoardingStatus.notBoarded);
    expect(BoardingStatus.verified.label, 'Boarding verified');
    expect(BoardingStatus.exception.label, 'Boarding exception');
  });

  test('filters map to the server wire values', () {
    expect(ManifestFilter.yetToBoard.wire, 'yet_to_board');
    expect(ManifestFilter.exceptions.wire, 'exceptions');
    expect([for (final f in ManifestFilter.values) f.label], ['All passengers', 'Yet to board', 'Boarded', 'Cancelled', 'Exceptions']);
  });

  test('query value equality (provider cache key)', () {
    expect(const ManifestQuery('t', ManifestFilter.all, 'a'), const ManifestQuery('t', ManifestFilter.all, 'a'));
    expect(const ManifestQuery('t', ManifestFilter.all, 'a'), isNot(const ManifestQuery('t', ManifestFilter.boarded, 'a')));
  });

  test('boarding results and error messages', () {
    expect(BoardingResult.fromJson({'ok': false, 'code': 'already_boarded', 'message': 'x'}).ok, isFalse);
    expect(BoardingResult.fromJson({'ok': true, 'status': 'verified'}).status, 'verified');
    expect(boardingErrorMessage(Exception('service_inactive: ...')), contains('not active'));
    expect(boardingErrorMessage(Exception('Only the operator admin can view the full document number')), contains('owner'));
  });
}
