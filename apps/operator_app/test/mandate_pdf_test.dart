import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:operator_app/features/onboarding/mandate_pdf.dart';

void main() {
  test('generates a non-empty PDF for full and empty data', () async {
    const full = MandateFormData(
      legalName: 'Andaman Express Pvt Ltd',
      businessName: 'Andaman Express',
      ownerName: 'A Owner',
      address: '1 Main St, Port Blair, South Andaman, Andaman and Nicobar Islands, 744101',
      accountHolder: 'Andaman Express Pvt Ltd',
      bankName: 'State Bank of India',
      branchName: 'Port Blair',
      accountNumber: '123456789012',
      ifsc: 'SBIN0001234',
      accountType: 'current',
    );
    const empty = MandateFormData(
      legalName: '', businessName: '', ownerName: '', address: '', accountHolder: '',
      bankName: '', branchName: '', accountNumber: '', ifsc: '', accountType: '',
    );

    for (final data in [full, empty]) {
      final bytes = await buildMandatePdf(data);
      expect(bytes.length, greaterThan(500));
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    }
  });

  test('template version is recorded for uploads', () {
    expect(mandateTemplateVersion, isNotEmpty);
  });
}
