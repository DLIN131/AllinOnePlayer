import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'model.dart';

/// 一筆觀看／閱讀紀錄
class HistoryEntry {
  final Item item;
  final int time;

  /// 影片：播放位置、長度（毫秒）；看完 = position 0
  final int position;
  final int duration;

  /// 漫畫：章節、頁數
  final String chapterId;
  final String chapterTitle;
  final int page;
  final int total;

  /// 影片劇集：上次看的那一集
  final Item? episode;

  const HistoryEntry(this.item, this.time,
      {this.position = 0, this.duration = 0, this.chapterId = '', this.chapterTitle = '', this.page = 0, this.total = 0, this.episode});

  double get progress => item.type == 'comic' ? (total > 0 ? (page + 1) / total : 0) : (duration > 0 ? position / duration : 0);

  Map<String, Object?> toJson() => {
        'item': item.toJson(),
        't': time,
        if (position > 0) 'pos': position,
        if (duration > 0) 'dur': duration,
        if (chapterId.isNotEmpty) 'ch': chapterId,
        if (chapterTitle.isNotEmpty) 'cht': chapterTitle,
        if (page > 0) 'page': page,
        if (total > 0) 'total': total,
        if (episode != null) 'ep': episode!.toJson(),
      };

  factory HistoryEntry.fromJson(Map j) => HistoryEntry(
        Item.fromJson(j['item'] as Map),
        (j['t'] as num?)?.toInt() ?? 0,
        position: (j['pos'] as num?)?.toInt() ?? 0,
        duration: (j['dur'] as num?)?.toInt() ?? 0,
        chapterId: j['ch'] ?? '',
        chapterTitle: j['cht'] ?? '',
        page: (j['page'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        episode: j['ep'] is Map ? Item.fromJson(j['ep'] as Map) : null,
      );
}

/// App 的本機資料：收藏、紀錄、搜尋字、設定、帳號名稱、書櫃合集…
/// 全部存在一個 state.json（先寫暫存檔再改名、保留 .bak，寫到一半當機也不會壞掉）。
class Store extends ChangeNotifier {
  static final Store instance = Store._();
  Store._();

  late File _file;
  Map<String, dynamic> _data = {};
  Timer? _saveTimer;
  bool _ready = false;

  static const _maxHistory = 500;

  Future<void> load(String dir) async {
    _file = File('$dir/state.json');
    for (final f in [_file, File('${_file.path}.bak')]) {
      try {
        if (await f.exists()) {
          _data = Map<String, dynamic>.from(jsonDecode(await f.readAsString()) as Map);
          break;
        }
      } catch (_) {}
    }
    _ready = true;
  }

  /// 測試用：不碰檔案
  void loadMemory([Map<String, dynamic>? data]) {
    _data = data ?? {};
    _ready = false;
  }

  void _changed() {
    notifyListeners();
    if (!_ready) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), save);
  }

  Future<void> save() async {
    if (!_ready) return;
    _saveTimer?.cancel();
    final text = jsonEncode(_data);
    try {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      if (await _file.exists()) await _file.copy('${_file.path}.bak');
      await tmp.rename(_file.path);
    } catch (_) {}
  }

  T _get<T>(String k, T def) {
    final v = _data[k];
    return v is T ? v : def;
  }

  // ---------- 收藏（本機） ----------

  List<Item> get favorites => [for (final e in _get<List>('favorites', const [])) Item.fromJson((e as Map)['item'] as Map)];

  bool isFavorite(String key) => _get<List>('favorites', const []).any((e) => Item.fromJson((e as Map)['item'] as Map).key == key);

  void setFavorite(Item item, bool on) {
    final list = List.of(_get<List>('favorites', const []))..removeWhere((e) => Item.fromJson((e as Map)['item'] as Map).key == item.key);
    if (on) list.insert(0, {'item': item.toJson(), 't': DateTime.now().millisecondsSinceEpoch});
    _data['favorites'] = list;
    _changed();
  }

  // ---------- 紀錄 ----------

  List<HistoryEntry> get history => [for (final e in _get<List>('history', const [])) HistoryEntry.fromJson(e as Map)];

  HistoryEntry? historyOf(String key) {
    for (final e in _get<List>('history', const [])) {
      final h = HistoryEntry.fromJson(e as Map);
      if (h.item.key == key) return h;
    }
    return null;
  }

  void addHistory(HistoryEntry h) {
    final list = List.of(_get<List>('history', const []))..removeWhere((e) => Item.fromJson((e as Map)['item'] as Map).key == h.item.key);
    list.insert(0, h.toJson());
    if (list.length > _maxHistory) list.removeRange(_maxHistory, list.length);
    _data['history'] = list;
    _changed();
  }

  void removeHistory(String key) {
    _data['history'] = List.of(_get<List>('history', const []))..removeWhere((e) => Item.fromJson((e as Map)['item'] as Map).key == key);
    _changed();
  }

  void clearHistory({bool? comics}) {
    if (comics == null) {
      _data['history'] = [];
    } else {
      _data['history'] = List.of(_get<List>('history', const []))..removeWhere((e) => (Item.fromJson((e as Map)['item'] as Map).type == 'comic') == comics);
    }
    _changed();
  }

  /// 影片續播位置（毫秒）；劇集的每一集各自記
  int position(String key) => _get<Map>('positions', const {})[key] as int? ?? 0;

  void setPosition(String key, int ms) {
    final m = Map<String, dynamic>.from(_get<Map>('positions', const {}));
    if (ms <= 0) {
      m.remove(key);
    } else {
      m[key] = ms;
    }
    // 只留最近 800 筆
    if (m.length > 800) m.remove(m.keys.first);
    _data['positions'] = m;
    _changed();
  }

  // ---------- 搜尋字 ----------

  List<String> get searches => [for (final e in _get<List>('searches', const [])) '$e'];

  void addSearch(String q) {
    q = q.trim();
    if (q.isEmpty) return;
    final list = searches..remove(q);
    list.insert(0, q);
    _data['searches'] = list.take(20).toList();
    _changed();
  }

  void clearSearches() {
    _data['searches'] = [];
    _changed();
  }

  // ---------- 設定 ----------

  Map<String, dynamic> get settings => Map<String, dynamic>.from(_get<Map>('settings', const {}));

  T setting<T>(String k, T def) {
    final v = settings[k];
    return v is T ? v : def;
  }

  void setSetting(String k, Object? v) {
    final s = settings;
    if (v == null) {
      s.remove(k);
    } else {
      s[k] = v;
    }
    _data['settings'] = s;
    _changed();
  }

  // ---------- 帳號（只記名稱，不記密碼） ----------

  Map<String, dynamic> account(String site) => Map<String, dynamic>.from((_get<Map>('accounts', const {})[site] as Map?) ?? const {});

  void setAccount(String site, Map<String, dynamic>? v) {
    final all = Map<String, dynamic>.from(_get<Map>('accounts', const {}));
    if (v == null) {
      all.remove(site);
    } else {
      all[site] = v;
    }
    _data['accounts'] = all;
    _changed();
  }

  void updateAccount(String site, void Function(Map<String, dynamic>) fn) {
    final a = account(site);
    fn(a);
    setAccount(site, a);
  }

  // ---------- 其他（書櫃合集、更新…） ----------

  Object? raw(String k) => _data[k];

  void setRaw(String k, Object? v) {
    if (v == null) {
      _data.remove(k);
    } else {
      _data[k] = v;
    }
    _changed();
  }

  Map<String, dynamic> snapshot() => Map<String, dynamic>.from(_data);
}
