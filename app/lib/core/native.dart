import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

/// 一次請求的結果；url 是轉址後的最後網址
class Resp {
  final int status;
  final String url;
  final String text;
  Resp(this.status, this.url, this.text);
  bool get ok => status >= 200 && status < 300;
}

/// 連線錯誤（訊息是給使用者看的中文）
class NetError implements Exception {
  final String message;
  final int status;
  NetError(this.message, [this.status = 0]);
  @override
  String toString() => message;
}

/// 被 Cloudflare 擋下，要使用者開驗證頁手動過
class BlockedError extends NetError {
  final String site;
  BlockedError(this.site) : super('需要通過網站驗證，請按「開啟驗證頁」完成後再試');
}

/// 沒登入或登入過期
class LoginError extends NetError {
  final String site;
  LoginError(this.site, [String? msg]) : super(msg ?? '登入已過期，請重新登入');
}

class DeviceInfo {
  final bool isTv;
  final String version;
  final int versionCode;
  final String apkName;
  final String userAgent;
  final String filesDir;
  final String externalDir;
  final String cacheDir;
  DeviceInfo(Map m)
      : isTv = m['isTv'] == true,
        version = m['version'] ?? '1.0.dev',
        versionCode = (m['versionCode'] as num?)?.toInt() ?? 0,
        apkName = m['apkName'] ?? '',
        userAgent = m['userAgent'] ?? '',
        filesDir = m['filesDir'] ?? '',
        externalDir = m['externalDir'] ?? '',
        cacheDir = m['cacheDir'] ?? '';

  /// 測試（沒有原生層）時用
  DeviceInfo.fake({this.isTv = false})
      : version = '1.0.dev',
        versionCode = 0,
        apkName = 'AllinOnePlayer.apk',
        userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
        filesDir = '.',
        externalDir = '.',
        cacheDir = '.';

  bool get isDev => version.contains('dev');
}

/// 原生層（Kotlin）：網路請求、cookie、播放器、驗證網頁、影片下載
class Native {
  static const _ch = MethodChannel('aio/native');
  static const _events = EventChannel('aio/events');

  static late DeviceInfo info;
  static Stream<Map>? _stream;

  /// 原生事件：{type: web|downloads, ...}
  static Stream<Map> get events => _stream ??= _events.receiveBroadcastStream().map((e) => Map.from(e as Map)).asBroadcastStream();

  static Future<void> init() async {
    try {
      info = DeviceInfo(await _ch.invokeMethod('info') as Map);
    } on MissingPluginException {
      info = DeviceInfo.fake();
    }
  }

  static Future<void> configure(List<Map<String, Object?>> sites) => _ch.invokeMethod('configure', {'sites': sites});

  /// 送請求。web = true：一律在隱藏 WebView 裡送；json = true：網站自己的 JSON API（帶 XSRF 等標頭）
  static Future<Resp> fetch(
    String site,
    String url, {
    String method = 'GET',
    String? body,
    String? contentType,
    Map<String, String>? headers,
    bool web = false,
    bool json = false,
  }) async {
    try {
      final r = await _ch.invokeMethod('fetch', {
        'site': site,
        'url': url,
        'method': method,
        'body': body,
        'contentType': contentType,
        'headers': headers ?? const {},
        'web': web,
        'json': json,
      }) as Map;
      return Resp((r['status'] as num).toInt(), r['url'] as String? ?? url, r['text'] as String? ?? '');
    } on PlatformException catch (e) {
      if (e.code == 'blocked') throw BlockedError(e.details as String? ?? site);
      throw NetError(e.message ?? '連線失敗', (e.details as num?)?.toInt() ?? 0);
    }
  }

  static Future<String?> cookie(String url, String name) async => await _ch.invokeMethod('cookie', {'url': url, 'name': name}) as String?;

  static Future<void> clearCookies(String site) => _ch.invokeMethod('clearCookies', {'site': site});

  static Future<void> resetWeb(String site) => _ch.invokeMethod('resetWeb', {'site': site});

  /// 登入確認成功：備份這個站的 cookie（重開 App 時補回被丟掉的登入 cookie）
  static Future<void> loginKeep(String site) => _ch.invokeMethod('loginKeep', {'site': site});

  /// 網站那邊真的過期了：不要再補舊的 cookie
  static Future<void> loginForget(String site) => _ch.invokeMethod('loginForget', {'site': site});

  /// 登入頁剛打的密碼要不要問使用者記住（已經記住過的會直接更新、回傳 false）
  static Future<bool> credOffer(String site) async => await _ch.invokeMethod('credOffer', {'site': site}) == true;

  static Future<bool> credRemember(String site, bool yes) async => await _ch.invokeMethod('credRemember', {'site': site, 'yes': yes}) == true;

  static Future<bool> credHas(String site) async => await _ch.invokeMethod('credHas', {'site': site}) == true;

  static Future<void> credForget(String site) => _ch.invokeMethod('credForget', {'site': site});

  /// 用記住的密碼在隱藏網頁重新登入；check 是要登入才看得到的頁面
  static Future<bool> autoLogin(String site, String url, String check) async =>
      await _ch.invokeMethod('autoLogin', {'site': site, 'url': url, 'check': check}) == true;

  /// 開看得到的網頁（login / verify / browse），關閉後回傳登入頁上打的帳號（只有 JM 會記）
  static Future<String> openWeb({required String site, required String url, required String mode, String title = '', String prefill = ''}) async {
    final r = await _ch.invokeMethod('openWeb', {'site': site, 'url': url, 'mode': mode, 'title': title, 'prefill': prefill}) as Map?;
    return r?['typed'] as String? ?? '';
  }

  static Future<void> closeWeb() => _ch.invokeMethod('closeWeb');

  /// 開播放器；關閉後回傳 {position, duration, next}（毫秒）
  static Future<Map> play(Map<String, Object?> req) async => (await _ch.invokeMethod('play', req) as Map?) ?? const {};

  static Future<List<Map>> downloads() async {
    final s = await _ch.invokeMethod('dl.list') as String;
    return [for (final e in _decodeList(s)) Map.from(e)];
  }

  static Future<List<Map>> variants(String url, Map<String, Object?> conn) async {
    final r = await _ch.invokeMethod('dl.variants', {'url': url, 'conn': conn}) as List;
    return [for (final e in r) Map.from(e as Map)];
  }

  static Future<void> startDownload(Map<String, Object?> args) => _ch.invokeMethod('dl.start', args);
  static Future<void> pauseDownload(String key) => _ch.invokeMethod('dl.pause', {'key': key});
  static Future<void> resumeDownload(String key) => _ch.invokeMethod('dl.resume', {'key': key});
  static Future<void> deleteDownload(String key) => _ch.invokeMethod('dl.delete', {'key': key});
  static Future<int> freeSpace() async => ((await _ch.invokeMethod('freeSpace')) as num).toInt();
  static Future<void> installApk(String path) => _ch.invokeMethod('installApk', {'path': path});
  static Future<void> shareFile(String path, String mime) => _ch.invokeMethod('shareFile', {'path': path, 'mime': mime});

  static List _decodeList(String s) => s.isEmpty ? const [] : (jsonDecode(s) as List);
}
