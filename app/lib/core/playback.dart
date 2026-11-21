import 'dart:async';

import 'package:flutter/foundation.dart';

import 'model.dart';
import 'native.dart';
import 'registry.dart';
import 'store.dart';

/// 播放：問來源要播放網址 → 開原生播放器 → 關閉後記下續播位置和紀錄；選「下一集」就接著播。
class Playback {
  static final _store = Store.instance;

  /// d：作品頁；episode：劇集裡的某一集（null = 作品本身）
  static Future<void> play(Detail d, {Item? episode}) async {
    final s = src(d.item.src);
    var ep = episode;
    // 劇集頁本身不能播：直接從第一集開始
    if (ep == null && d.item.type == 'series' && d.episodes.isNotEmpty) ep = d.episodes.first;
    while (true) {
      final stream = await s.stream(d, episode: ep);
      final key = (ep ?? d.item).key;
      final title = ep != null && ep.key != d.item.key ? '${d.title}　${ep.title}' : d.title;
      final next = _next(d, ep);
      final r = await _launch(stream, key, title, next != null);
      _record(d.item, ep, key, r);
      if (r['next'] == true && next != null) {
        ep = next;
        continue;
      }
      break;
    }
  }

  /// 已下載的影片（本機檔案）
  static Future<void> playLocal(Item item, String file) async {
    final r = await _launch(Stream('local', file), item.key, item.title, false);
    _record(item, null, item.key, r);
  }

  static Item? _next(Detail d, Item? ep) {
    final list = d.episodes;
    if (list.isEmpty) return null;
    final cur = ep ?? d.item;
    final i = list.indexWhere((e) => e.key == cur.key);
    if (i < 0 || i + 1 >= list.length) return null;
    return list[i + 1];
  }

  static Future<Map> _launch(Stream st, String key, String title, bool hasNext) => Native.play({
        'key': key,
        'title': title,
        'kind': st.kind,
        'url': st.url,
        'qualities': [for (final q in st.qualities) {'label': q.$1, 'url': q.$2}],
        'headers': st.headers,
        'cronet': st.cronet,
        'unwrap': st.unwrap,
        'startMs': _store.position(key),
        'hasNext': hasNext,
      });

  static void _record(Item item, Item? ep, String key, Map r) {
    final pos = (r['position'] as num?)?.toInt() ?? 0;
    final dur = (r['duration'] as num?)?.toInt() ?? 0;
    // 看到最後 30 秒內就當作看完，下次從頭開始
    final done = dur > 0 && dur - pos < 30000;
    if (pos > 0) _store.setPosition(key, done ? 0 : pos);
    _store.addHistory(HistoryEntry(item, DateTime.now().millisecondsSinceEpoch, position: done ? 0 : pos, duration: dur, episode: ep));
  }
}

/// 手機版的影片下載（實際下載在原生層，這裡只是狀態）
class VideoDownloads extends ChangeNotifier {
  static final VideoDownloads instance = VideoDownloads._();
  VideoDownloads._();

  List<Map> items = [];
  StreamSubscription? _sub;

  Future<void> init() async {
    _sub ??= Native.events.listen((e) {
      if (e['type'] == 'downloads') _set(e['items'] as String? ?? '[]');
    });
    try {
      items = await Native.downloads();
      notifyListeners();
    } catch (_) {}
  }

  void _set(String json) async {
    try {
      items = await Native.downloads();
    } catch (_) {}
    notifyListeners();
  }

  Map? find(String key) => items.where((e) => e['key'] == key).firstOrNull;

  /// 開始下載：HLS 會先讓使用者選畫質（variantUrl），MP4 直接給網址
  Future<void> start(Detail d, Stream st, {Item? episode, String? url, String quality = ''}) async {
    final it = episode ?? d.item;
    await Native.startDownload({
      'key': it.key,
      'kind': st.kind == 'mp4' ? 'mp4' : 'hls',
      'url': url ?? st.url,
      'conn': st.conn,
      'quality': quality,
      'meta': {
        ...it.toJson(),
        'title': episode != null ? '${d.title}　${episode.title}' : d.title,
        'cover': it.cover.isNotEmpty ? it.cover : d.cover,
        'coverHeaders': src(d.item.src).imageHeaders,
      },
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
