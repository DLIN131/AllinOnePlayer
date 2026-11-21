/// 漫畫四站共用：語言判斷、編號搜尋、書名整理
library;

import '../sites.dart';

class Lang {
  static const names = {'zh': '中文', 'en': 'English', 'ja': '日本語'};
  static const short = {'zh': '中', 'en': 'EN', 'ja': '日'};

  /// 目前的語言篩選（'' = 全部）；NH、EH 可以請伺服器篩，另外兩站在畫面端篩
  static String filter = '';

  static final _rules = [
    ('zh', RegExp(r'chinese|中文|漢化|汉化|中国翻訳|中國翻譯|中国翻译|中譯|中译|个人翻译|個人翻譯|翻譯|翻译', caseSensitive: false)),
    ('en', RegExp(r'english|英文|英訳|英語|英语', caseSensitive: false)),
    ('ja', RegExp(r'japanese|日文|日語|日语|日本語', caseSensitive: false)),
  ];

  /// 從分類、標籤、標題猜語言；越前面的線索越可信
  static String detect(List<String?> hints) {
    for (final h in hints) {
      if (h == null || h.trim().isEmpty) continue;
      for (final (lang, re) in _rules) {
        if (re.hasMatch(h)) return lang;
      }
    }
    return '';
  }

  static final _bracket = RegExp(r'[\[【(（][^\]】)）]{1,30}[\]】)）]');

  /// 標題裡 [Chinese]、[英訳] 這類方括號標記
  static String bracketTags(String? title) => _bracket.allMatches(title ?? '').map((m) => m.group(0)).join(' ');
}

class IdQuery {
  final List<String> sites;
  final String id;
  final bool plain;
  const IdQuery(this.sites, this.id, {this.plain = false});
}

class Query {
  /// 判斷搜尋字是不是編號：
  ///   站別代號、站名、各站編號前綴＋編號（例如 JM123、#123）→ 只查那一站
  ///   作品網址 → 依網址判斷是哪一站
  ///   純數字 → 每個漫畫站都用這個編號查一次
  static IdQuery? parseId(String q) {
    final s = q.trim();
    final t = s.replaceAll(RegExp(r'\s+'), '');
    IdQuery one(String site, String id) => IdQuery([site], int.parse(id).toString());
    String hostName(String k) {
      final p = Sites.host(k).split('.');
      return p.length >= 2 ? p[p.length - 2] : p.first;
    }

    final eh = RegExp(r'/g/(\d+)/([0-9a-f]{10})').firstMatch(s);
    if (eh != null && s.contains(hostName('eh'))) return IdQuery(['eh'], '${eh.group(1)}_${eh.group(2)}');
    final nh = RegExp(r'/g/(\d+)').firstMatch(s);
    if (nh != null && s.contains(hostName('nh'))) return one('nh', nh.group(1)!);
    final jm = RegExp(r'/(?:album|photo)/(\d+)').firstMatch(s);
    if (jm != null) return one('jm', jm.group(1)!);
    final wn = RegExp(r'aid-(\d+)').firstMatch(s);
    if (wn != null) return one('wn', wn.group(1)!);
    final numbered = Sites.comicKeys.where((k) => k != 'eh').toList();
    for (final k in numbered) {
      final label = Sites.label(k);
      final names = [k, Sites.prefix(k), label, label.length > 2 ? label.substring(0, 2) : label, hostName(k)].where((e) => e.isNotEmpty).map(RegExp.escape);
      final m = RegExp('^(?:${names.join('|')})(\\d{1,9})\$', caseSensitive: false).firstMatch(t);
      if (m != null) return one(k, m.group(1)!);
    }
    final plain = RegExp(r'^\d{1,8}$').firstMatch(t);
    if (plain != null) return IdQuery(numbered, int.parse(plain.group(0)!).toString(), plain: true);
    return null;
  }

  /// 書名開頭的 [社團 (作者)] 或 [作者]，拆出作者名
  static List<String> parseAuthors(String title) {
    final m = RegExp(r'^\s*(?:\([^)]*\)\s*)?\[([^\]]+)]').firstMatch(title);
    if (m == null) return const [];
    final head = m.group(1)!;
    if (RegExp(r'翻訳|翻譯|汉化|漢化|chinese|english|中文|DL版|digital', caseSensitive: false).hasMatch(head)) return const [];
    final inner = RegExp(r'^(.*?)\s*\(([^)]+)\)\s*$').firstMatch(head);
    final names = inner != null ? [...inner.group(2)!.split(RegExp(r'[,、，]')), inner.group(1)!] : head.split(RegExp(r'[,、，]'));
    return names.map((e) => e.trim()).where((e) => e.isNotEmpty && e.length < 40).toSet().toList();
  }

  /// 拿掉 [社團]、(活動)、{漢化組}、【…】 這些標記，剩下書名本體，拿來到各站搜同一本
  static String cleanTitle(String t) {
    final s = t
        .split(RegExp(r'\s[|｜]\s'))
        .first
        .replaceAll(RegExp(r'\[[^\]]*]|\([^)]*\)|\{[^}]*}|【[^】]*】|（[^）]*）'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return s.length >= 2 ? s : t.trim();
  }
}
