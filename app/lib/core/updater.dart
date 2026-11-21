import 'dart:convert';
import 'dart:io';

import 'fetch_bytes.dart';
import 'native.dart';
import 'store.dart';

class Release {
  final int build;
  final String tag;
  final String title;
  final List<String> notes;
  final String date;
  final Map<String, String> assets; // 檔名 → 下載網址
  const Release(this.build, this.tag, this.title, this.notes, this.date, this.assets);

  /// 發布說明：第一行是標題，其餘是條列；「---」以下是固定的下載網址，不顯示
  factory Release.fromJson(Map j) {
    final tag = '${j['tag_name'] ?? ''}';
    final body = '${j['body'] ?? ''}'.split('\n---').first;
    final lines = body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty && !l.startsWith('Co-Authored-By')).toList();
    return Release(
      int.tryParse(tag.split('.').last) ?? 0,
      tag,
      lines.isEmpty ? tag : lines.first.replaceFirst(RegExp(r'^[-*]\s*'), ''),
      [for (final l in lines.skip(1)) l.replaceFirst(RegExp(r'^[-*]\s*'), '')],
      '${j['published_at'] ?? ''}'.split('T').first,
      {for (final a in (j['assets'] as List? ?? const [])) if (a is Map) '${a['name']}': '${a['browser_download_url']}'},
    );
  }
}

/// App 內更新：GitHub Releases 的最新版（tag v1.0.<build>），依檔名挑自己的安裝檔（手機 / 電視不同）
class Updater {
  static const repo = 'DLIN131/AllinOnePlayer';

  static Future<List<Release>> releases() async {
    final b = await fetchBytes('https://api.github.com/repos/$repo/releases?per_page=30', headers: {'Accept': 'application/vnd.github+json'});
    final list = jsonDecode(utf8.decode(b)) as List;
    return [for (final r in list) if (r is Map && r['draft'] != true) Release.fromJson(r)];
  }

  static Future<Release> latest() async {
    final b = await fetchBytes('https://api.github.com/repos/$repo/releases/latest', headers: {'Accept': 'application/vnd.github+json'});
    return Release.fromJson(jsonDecode(utf8.decode(b)) as Map);
  }

  /// 有新版回傳 Release；開發版不檢查（manual = true 時也照樣檢查）
  static Future<Release?> check({bool manual = false}) async {
    if (Native.info.isDev && !manual) return null;
    final r = await latest();
    if (r.build <= Native.info.versionCode) return null;
    if (!manual && Store.instance.setting<int>('skippedVersion', 0) == r.build) return null;
    if (!r.assets.containsKey(Native.info.apkName)) return null;
    return r;
  }

  static Future<void> install(Release r, void Function(double) onProgress) async {
    final url = r.assets[Native.info.apkName]!;
    final bytes = await fetchBytes(url, onProgress: (got, total) => onProgress(total > 0 ? got / total : 0));
    final dir = Directory('${Native.info.cacheDir}/updates');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final f = File('${dir.path}/${Native.info.apkName}');
    await f.writeAsBytes(bytes, flush: true);
    await Native.installApk(f.path);
  }
}
