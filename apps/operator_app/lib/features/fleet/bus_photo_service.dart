import 'dart:convert';
import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
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
  Future<String> upload({required String busId, required String side, required String localPath}) {
    final contentType = _contentType(localPath);
    return _presignAndPut(localPath, contentType, {'bus_id': busId, 'side': side, 'content_type': contentType});
  }

  /// Uploads a private bus document to R2 and returns its object key. PDFs go
  /// up as-is; any other file is treated as an image, converted to WebP and
  /// compressed first.
  Future<String> uploadDocument({required String busId, required String docType, required String localPath}) async {
    var path = localPath;
    var contentType = 'application/pdf';
    File? converted;
    if (!localPath.toLowerCase().endsWith('.pdf')) {
      converted = await _toWebp(localPath);
      path = converted.path;
      contentType = 'image/webp';
    }
    try {
      return await _presignAndPut(path, contentType, {'bus_id': busId, 'doc_type': docType, 'content_type': contentType});
    } finally {
      if (converted != null) {
        try {
          await converted.delete();
        } catch (_) {}
      }
    }
  }

  /// Converts any image (jpg, png, heic, gif, bmp, webp…) to a compressed WebP.
  static Future<File> _toWebp(String path) async {
    final out = '${Directory.systemTemp.path}/doc_${DateTime.now().microsecondsSinceEpoch}.webp';
    final result = await FlutterImageCompress.compressAndGetFile(
      path,
      out,
      format: CompressFormat.webp,
      quality: 80,
      minWidth: 2000,
      minHeight: 2000,
    );
    if (result == null) throw Exception('This file could not be read as an image or PDF. Please pick another file.');
    return File(result.path);
  }

  Future<String> _presignAndPut(String localPath, String contentType, Map<String, dynamic> body) async {
    final res = await _db.functions.invoke('r2-presign', body: body);
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
      final respBody = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('R2 upload failed (${resp.statusCode}): $respBody');
      }
    } finally {
      client.close();
    }
    return key;
  }
}
