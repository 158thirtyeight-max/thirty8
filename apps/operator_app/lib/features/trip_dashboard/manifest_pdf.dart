import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'manifest_models.dart';

/// Header facts printed on the passenger list.
class ManifestExportInfo {
  const ManifestExportInfo({
    required this.routeLabel,
    required this.busRegistration,
    required this.departureAt,
    required this.operatorName,
    this.bookingClosedAt,
  });

  final String routeLabel;
  final String busRegistration;
  final DateTime departureAt;
  final String operatorName;
  final DateTime? bookingClosedAt;
}

/// The PDF uses plain ASCII punctuation ("to", "-") so it prints correctly even when the Unicode font
/// cannot be downloaded and the built-in Helvetica is used.
///
/// Rows for the PDF table: only confirmed passengers, ID shown MASKED.
/// The list is for carrying on the bus, so it holds what is needed to check a passenger in
/// — never a full ID number.
List<List<String>> manifestExportRows(List<ManifestPassenger> passengers) {
  final confirmed = passengers.where((p) => p.isConfirmed).toList();
  return [
    for (var i = 0; i < confirmed.length; i++)
      [
        '${i + 1}',
        confirmed[i].seatCode,
        confirmed[i].name,
        confirmed[i].phone ?? '-',
        '${confirmed[i].boardingPoint} to ${confirmed[i].droppingPoint}',
        confirmed[i].bookingReference,
        confirmed[i].documentLine ?? 'No ID on file',
        '',
      ],
  ];
}

const manifestExportHeaders = ['#', 'Seat', 'Passenger', 'Phone', 'Boarding to Destination', 'Booking', 'ID (masked)', 'Boarded'];

/// `passenger-list_Port-Blair-Rangat_2026-10-05_AN01L5656.pdf`
String manifestExportFileName(ManifestExportInfo info) {
  String slug(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return 'passenger-list_${slug(info.routeLabel)}_${DateFormat('yyyy-MM-dd').format(info.departureAt)}_${slug(info.busRegistration)}.pdf';
}

/// Landscape A4 passenger list with a tick column, ready to print or share.
Future<Uint8List> buildManifestPdf(
  List<ManifestPassenger> passengers,
  ManifestExportInfo info, {
  DateTime? generatedAt,
  bool loadFonts = true,
}) async {
  final now = generatedAt ?? DateTime.now();
  final rows = manifestExportRows(passengers);
  final df = DateFormat('EEE, d MMM yyyy · h:mm a');

  pw.ThemeData? theme;
  if (loadFonts) {
    try {
      // Unicode font so Indian names with non-Latin letters print correctly; falls back to Helvetica offline.
      theme = pw.ThemeData.withFont(base: await PdfGoogleFonts.notoSansRegular(), bold: await PdfGoogleFonts.notoSansBold());
    } catch (_) {
      theme = null;
    }
  }

  final doc = pw.Document(title: 'Passenger list', author: info.operatorName, theme: theme);
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(28),
      header: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('Passenger list', style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.Text(info.routeLabel.replaceAll('→', 'to'), style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Text('${info.busRegistration} · Departs ${df.format(info.departureAt)} · ${info.operatorName}', style: const pw.TextStyle(fontSize: 10)),
        pw.Text(
          '${rows.length} confirmed passenger${rows.length == 1 ? '' : 's'}'
          '${info.bookingClosedAt == null ? '' : ' · Booking closed ${df.format(info.bookingClosedAt!)}'}',
          style: const pw.TextStyle(fontSize: 10),
        ),
        pw.SizedBox(height: 10),
      ]),
      footer: (c) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(
          'Generated ${df.format(now)}. ID numbers are masked. For boarding verification only. Keep this list confidential.',
          style: const pw.TextStyle(fontSize: 8),
        ),
        pw.Text('Page ${c.pageNumber} of ${c.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
      ]),
      build: (c) => [
        if (rows.isEmpty)
          pw.Text('No confirmed passengers on this trip.')
        else
          pw.TableHelper.fromTextArray(
            headers: manifestExportHeaders,
            data: rows,
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey300),
            cellAlignment: pw.Alignment.centerLeft,
            cellHeight: 22,
            columnWidths: {
              0: const pw.FixedColumnWidth(24),
              1: const pw.FixedColumnWidth(38),
              2: const pw.FlexColumnWidth(2.2),
              3: const pw.FlexColumnWidth(1.4),
              4: const pw.FlexColumnWidth(2.4),
              5: const pw.FlexColumnWidth(1.6),
              6: const pw.FlexColumnWidth(2),
              7: const pw.FixedColumnWidth(48),
            },
          ),
      ],
    ),
  );
  return doc.save();
}
