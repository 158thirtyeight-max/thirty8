import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Identifies which generated form an uploaded mandate was based on, stored in
/// operator_payment_mandates.template_version. Bump when the layout/wording
/// changes, or when the official form replaces this placeholder.
const mandateTemplateVersion = 'placeholder-v1';

class MandateFormData {
  const MandateFormData({
    required this.legalName,
    required this.businessName,
    required this.ownerName,
    required this.address,
    required this.accountHolder,
    required this.bankName,
    required this.branchName,
    required this.accountNumber,
    required this.ifsc,
    required this.accountType,
  });

  final String legalName;
  final String businessName;
  final String ownerName;
  final String address;
  final String accountHolder;
  final String bankName;
  final String branchName;
  final String accountNumber;
  final String ifsc;
  final String accountType;
}

/// Builds a printable, pre-filled payment mandate. This is a PLACEHOLDER
/// template: it is not a legally reviewed or bank-approved form and must be
/// replaced with the official mandate before production use.
Future<Uint8List> buildMandatePdf(MandateFormData d) async {
  final doc = pw.Document(title: 'Payment Mandate', author: 'Thirty8');
  final small = pw.TextStyle(fontSize: 9, color: PdfColors.grey700);
  final label = pw.TextStyle(fontSize: 10, color: PdfColors.grey800);
  final value = pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold);

  pw.Widget row(String l, String v) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(width: 150, child: pw.Text(l, style: label)),
            pw.Expanded(child: pw.Text(v.isEmpty ? '-' : v, style: value)),
          ],
        ),
      );

  pw.Widget box(String caption, double height) => pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(
              height: height,
              decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey600)),
            ),
            pw.SizedBox(height: 3),
            pw.Text(caption, style: small),
          ],
        ),
      );

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(40),
      build: (context) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('PAYMENT MANDATE', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 2),
          pw.Text(
            'Placeholder template ($mandateTemplateVersion) - not an official bank or legal form.',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.red800),
          ),
          pw.SizedBox(height: 16),
          pw.Text('Operator details', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.Divider(),
          row('Legal business name', d.legalName),
          row('Business / operator name', d.businessName),
          row('Authorized person', d.ownerName),
          row('Business address', d.address),
          pw.SizedBox(height: 12),
          pw.Text('Settlement bank account', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.Divider(),
          row('Account holder', d.accountHolder),
          row('Bank', d.bankName),
          row('Branch', d.branchName),
          row('Account number', d.accountNumber),
          row('IFSC', d.ifsc),
          row('Account type', d.accountType),
          pw.SizedBox(height: 16),
          pw.Text('Declaration', style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
          pw.Divider(),
          pw.Text(
            'I/We, the authorized signatory of the operator named above, confirm that the bank account '
            'details given are correct and authorize Thirty8 to remit booking settlements owed to the '
            'operator to this account, net of applicable commissions, refunds and adjustments, until '
            'this mandate is withdrawn in writing. I/We will inform Thirty8 promptly of any change to '
            'these details.',
            style: const pw.TextStyle(fontSize: 10, lineSpacing: 3),
          ),
          pw.SizedBox(height: 28),
          pw.Row(
            children: [
              box('Date & place', 40),
              pw.SizedBox(width: 16),
              box('Signature of authorized signatory', 60),
              pw.SizedBox(width: 16),
              box('Business stamp / seal', 60),
            ],
          ),
          pw.Spacer(),
          pw.Text(
            'Sign, stamp, scan or photograph this page clearly and upload it in the Thirty8 operator app.',
            style: small,
          ),
        ],
      ),
    ),
  );

  return doc.save();
}
