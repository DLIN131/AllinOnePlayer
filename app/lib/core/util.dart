import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as hp;

String b64(String s) => utf8.decode(base64.decode(s));

/// 網址編碼（空白是 %20，路徑和參數都能用）
String enc(String s) => Uri.encodeComponent(s);

dom.Document parseHtml(String s) => hp.parse(s);

/// 相對網址 → 絕對網址
String abs(String? u, String base) {
  if (u == null || u.trim().isEmpty) return '';
  u = u.trim();
  if (u.startsWith('//')) return 'https:$u';
  if (u.startsWith('http')) return u;
  if (u.startsWith('/')) return base + u;
  try {
    return Uri.parse('$base/').resolve(u).toString();
  } catch (_) {
    return u;
  }
}

extension ElementX on dom.Element? {
  /// 文字（空白收成一個）
  String get txt => (this?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  String attr(String name) => this?.attributes[name] ?? '';

  /// 往上找第一個符合 selector 的祖先（含自己）
  dom.Element? closest(String selector) {
    var e = this;
    while (e != null) {
      if (_matches(e, selector)) return e;
      e = e.parent;
    }
    return null;
  }
}

bool _matches(dom.Element e, String selector) {
  for (final part in selector.split(',')) {
    final s = part.trim();
    if (s.isEmpty) continue;
    final m = RegExp(r'^([a-zA-Z0-9]*)((?:\.[\w-]+)*)$').firstMatch(s);
    if (m == null) continue;
    final tag = m.group(1)!;
    final classes = m.group(2)!.split('.').where((c) => c.isNotEmpty);
    if (tag.isNotEmpty && e.localName != tag) continue;
    if (classes.every((c) => e.classes.contains(c))) return true;
  }
  return false;
}

/// 秒數 → h:mm:ss
String fmtTime(double sec) {
  final s = sec.isFinite ? sec.floor().clamp(0, 1 << 31) : 0;
  final h = s ~/ 3600, m = s % 3600 ~/ 60, ss = s % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(ss)}' : '$m:${two(ss)}';
}

/// 觀看次數：1.2 萬
String fmtCount(num n) {
  if (n >= 100000) return '${n ~/ 10000} 萬';
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)} 萬';
  return n.toInt().toString();
}

String fmtSize(num bytes) {
  if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(2)} GB';
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

String fmtDate(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

/// HTML 實體解碼（屬性值裡的 &amp; 等）
String unescapeHtml(String s) => hp.parseFragment(s).text ?? s;
