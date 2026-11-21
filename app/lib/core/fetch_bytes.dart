import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'native.dart';

/// 抓圖片等檔案的原始位元組（圖片 CDN 都不用過 Cloudflare，直接連）。失敗重試兩次。
final HttpClient _client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 15)
  ..idleTimeout = const Duration(seconds: 20);

Future<Uint8List> fetchBytes(String url, {Map<String, String> headers = const {}, int retries = 2, void Function(int got, int total)? onProgress}) async {
  Object? last;
  for (var i = 0; i <= retries; i++) {
    try {
      final req = await _client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, Native.info.userAgent);
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode == 404) throw HttpException('檔案不存在（HTTP 404）');
      if (res.statusCode < 200 || res.statusCode >= 300) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength;
      final b = BytesBuilder(copy: false);
      var got = 0;
      await for (final chunk in res.timeout(const Duration(seconds: 30))) {
        b.add(chunk);
        got += chunk.length;
        onProgress?.call(got, total);
      }
      return b.takeBytes();
    } on HttpException catch (e) {
      if (e.message.contains('404')) rethrow;
      last = e;
    } catch (e) {
      last = e;
    }
    await Future.delayed(Duration(seconds: i + 1));
  }
  throw NetError('下載失敗：$last');
}
