import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/env.dart';

/// Uploads bus photographs to Cloudflare R2. The r2-presign edge function
/// authorises the caller and returns a short-lived presigned PUT URL plus the
/// object key; the file goes straight to R2 and only the key is stored.
class BusPhotoService {
  BusPhotoService(this._db);
  final SupabaseClient _db;

  static const maxPerSide = 4;
  static const minPerSide = 2;

  static String publicUrl(String key) => '${R2Env.publicBaseUrl}/$key';

  static String _contentType(String path) {
    switch (path.split('.').last.toLowerCase()) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/jpeg';
    }
  }

  /// Uploads [localPath] and returns the stored object key.
  Future<String> upload({required String busId, required String side, required String localPath}) async {
    final contentType = _contentType(localPath);
    final res = await _db.functions.invoke('r2-presign', body: {
      'bus_id': busId,
      'side': side,
      'content_type': contentType,
    });
    final data = res.data as Map;
    final uploadUrl = data['upload_url'] as String;
    final key = data['key'] as String;

    final file = File(localPath);
    final client = HttpClient();
    try {
      final req = await client.putUrl(Uri.parse(uploadUrl));
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      req.contentLength = await file.length();
      await req.addStream(file.openRead());
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('R2 upload failed (${resp.statusCode}): $body');
      }
    } finally {
      client.close();
    }
    return key;
  }
}
