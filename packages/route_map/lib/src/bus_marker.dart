import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Draws the Thirty8 bus marker as a PNG for the map style: a coloured disc with a bus glyph.
/// With [withArrow] a pointer sits at the top, so rotating the image by the GPS heading makes the
/// pointer face the direction of travel. Without a heading no pointer is drawn (no invented direction).
Future<Uint8List> renderBusMarker({required Color color, required bool withArrow, bool hollow = false}) async {
  const size = 96.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
  const c = Offset(size / 2, size / 2);
  const r = 26.0;

  if (withArrow) {
    final p = Path()
      ..moveTo(c.dx, 2)
      ..lineTo(c.dx + 13, 26)
      ..lineTo(c.dx - 13, 26)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }
  canvas.drawCircle(c + const Offset(0, 2), r, Paint()..color = const Color(0x44000000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
  canvas.drawCircle(c, r, Paint()..color = hollow ? Colors.white : color);
  canvas.drawCircle(c, r, Paint()..style = PaintingStyle.stroke..strokeWidth = 4..color = hollow ? color : Colors.white);

  final icon = hollow ? Icons.help_outline : Icons.directions_bus;
  final tp = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontSize: 30, fontFamily: icon.fontFamily, package: icon.fontPackage, color: hollow ? color : Colors.white),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));

  final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
