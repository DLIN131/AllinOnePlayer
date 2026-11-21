import 'dart:convert';

import '../model.dart';
import '../native.dart';
import '../sites.dart';
import '../source.dart';
import 'comic_common.dart';

/// nh：官方 v2 API。登入 token 是 access_token cookie（原生層會自動帶 Authorization 並在 401 時換票）
class NhSource extends Source {
  NhSource() : super('nh');

  static const sorts = [('date', '最新'), ('popular-today', '今日熱門'), ('popular-week', '本週熱門'), ('popular', '歷來熱門')];
  static const _langIds = {29963: 'zh', 12227: 'en', 6346: 'ja'};
  static const _langNames = {'zh': 'chinese', 'en': 'english', 'ja': 'japanese'};

  @override
  List<Section> get sections => const [
        Section('latest', '最新', filters: [FilterSpec('sort', '排序', sorts)]),
        Section('fav', '網站收藏'),
      ];

  @override
  List<FilterSpec> get searchFilters => const [FilterSpec('sort', '排序', sorts)];

  @override
  bool get hasAccount => true;

  String img(String prefix, String? p) {
    if (p == null || p.trim().isEmpty) return '';
    if (p.startsWith('http')) return p;
    var h = 0;
    for (final c in p.codeUnits) {
      h = (h * 31 + c) & 0xFFFFFFFF;
    }
    // 跟 Kotlin 的 Int 溢位一樣（有號 32 位元）
    final signed = h >= 0x80000000 ? h - 0x100000000 : h;
    // Kotlin 的 % 保留負號（Dart 的 % 不會），要用 remainder
    final n = signed.remainder(4).abs() + 1;
    return 'https://$prefix$n.${Sites.host(key)}/${p.replaceFirst(RegExp(r'^/+'), '')}';
  }

  String? _thumb(Map o, String name) {
    final v = o[name];
    if (v is Map) return v['path'] as String?;
    if (v is String && v.trim().isNotEmpty) return v;
    return null;
  }

  Item item(Map o) {
    final t = o['title'] is Map ? o['title'] as Map : const {};
    String title = (o['english_title'] ?? '') as String;
    if (title.isEmpty) title = (o['japanese_title'] ?? '') as String;
    if (title.isEmpty) title = (t['english'] ?? '') as String;
    if (title.isEmpty) title = '#${o['id']}';
    final ids = (o['tag_ids'] is List) ? (o['tag_ids'] as List).whereType<num>().map((e) => e.toInt()).toList() : const <int>[];
    // 翻譯本同時有 japanese 以外的語言標籤，先看中英
    var lang = '';
    for (final l in ['zh', 'en', 'ja']) {
      if (ids.any((i) => _langIds[i] == l)) {
        lang = l;
        break;
      }
    }
    if (lang.isEmpty) lang = Lang.detect([Lang.bracketTags(title)]);
    final pages = (o['num_pages'] as num?)?.toInt() ?? 0;
    return Item(src: key, id: '${o['id']}', title: title, cover: img('t', _thumb(o, 'thumbnail')), sub: '${pages > 0 ? pages : '?'} 頁', type: 'comic', poster: true, lang: lang);
  }

  PageResult parsePage(Map o, int page) {
    final a = o['result'] is List ? o['result'] as List : const [];
    return PageResult([for (final e in a) if (e is Map) item(e)], page < ((o['num_pages'] as num?)?.toInt() ?? 1));
  }

  /// 有語言篩選時把 language:xxx 加進查詢，伺服器就只回那個語言
  String _withLang(String q) => [q.trim(), if (_langNames[Lang.filter] != null) 'language:${_langNames[Lang.filter]}'].where((e) => e.isNotEmpty).join(' ');

  @override
  Future<PageResult> list(Map<String, String> params, int page) async {
    if (params['section'] == 'fav') return favorites(page);
    if (params['q'] != null) return search(params['q']!, page, params);
    final sort = params['sort'] ?? 'date';
    if (sort == 'date' && Lang.filter.isEmpty) return parsePage(await Http.json(key, '/api/v2/galleries?page=$page&per_page=25'), page);
    return search('', page, {'sort': sort});
  }

  @override
  Future<PageResult> search(String q, int page, Map<String, String> params) async {
    final query = Uri.encodeComponent(_withLang(q).isEmpty ? 'pages:>0' : _withLang(q));
    return parsePage(await Http.json(key, '/api/v2/search?query=$query&sort=${params['sort'] ?? 'date'}&page=$page'), page);
  }

  static const _typeName = {'artist': '作者', 'group': '社團', 'parody': '原作', 'character': '角色', 'tag': '標籤', 'language': '語言', 'category': '分類'};

  @override
  Future<Detail> detail(Item it) async => parseDetail(await Http.json(key, '/api/v2/galleries/${it.id}?include=related'));

  Detail parseDetail(Map o) {
    final id = '${o['id']}';
    final order = _typeName.keys.toList();
    final raw = [for (final t in (o['tags'] as List? ?? const [])) if (t is Map) t]..sort((a, b) => order.indexOf('${a['type']}').compareTo(order.indexOf('${b['type']}')));
    final tags = [
      for (final t in raw) Link(key, '${_typeName[t['type']] ?? t['type']}：${t['name']}', {'q': '${t['type']}:"${t['name']}"'}),
    ];
    final title = o['title'] is Map ? o['title'] as Map : const {};
    final pages = [
      for (final p in (o['pages'] as List? ?? const []))
        if (p is Map) ComicPage(img('i', p['path'] as String?), width: (p['width'] as num?)?.toInt() ?? 0, height: (p['height'] as num?)?.toInt() ?? 0),
    ];
    final upload = (o['upload_date'] as num?)?.toInt() ?? 0;
    final langNames = raw.where((t) => t['type'] == 'language' && t['name'] != 'translated').map((t) => t['name']).join(' ');
    final numPages = (o['num_pages'] as num?)?.toInt() ?? 0;
    var t = (title['english'] ?? '') as String;
    if (t.isEmpty) t = (title['pretty'] ?? '') as String;
    if (t.isEmpty) t = '#$id';
    final cover = img('t', _thumb(o, 'cover') ?? _thumb(o, 'thumbnail'));
    final lang = Lang.detect([langNames]);
    return Detail(
      item: Item(src: key, id: id, title: t, cover: cover, sub: '$numPages 頁', type: 'comic', poster: true, lang: lang),
      title: t,
      subtitle: (title['japanese'] ?? '') as String,
      cover: cover,
      tags: tags,
      lang: lang,
      info: [
        InfoRow('編號', '#$id'),
        InfoRow('頁數', '$numPages'),
        InfoRow('收藏數', o.containsKey('num_favorites') ? '${o['num_favorites']}' : '-'),
        InfoRow('上傳', upload > 0 ? _date(upload) : '-'),
      ],
      pages: numPages > 0 ? numPages : null,
      related: [for (final r in (o['related'] as List? ?? const [])) if (r is Map) item(r)],
      url: '$base/g/$id/',
      extra: {'reader': pages},
    );
  }

  String _date(int sec) {
    final d = DateTime.fromMillisecondsSinceEpoch(sec * 1000);
    return '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Future<List<ComicPage>> read(Detail d, String? chapterId) async {
    final r = d.extra['reader'] as List<ComicPage>?;
    if (r != null && r.isNotEmpty) return r;
    return (await detail(d.item)).extra['reader'] as List<ComicPage>? ?? const [];
  }

  @override
  Future<PageResult> favorites(int page) async {
    final r = await Http.fetch(key, '/api/v2/favorites?page=$page');
    if (r.status == 401 || r.status == 403) throw LoginError(key, '還沒登入${Sites.label(key)}');
    if (!r.ok) throw NetError(Http.errorText(r), r.status);
    return parsePage(Map.from(jsonDecode(r.text) as Map), page);
  }

  Future<bool> isFavorite(String id) async {
    final o = await Http.json(key, '/api/v2/galleries/$id/favorite');
    return o['favorited'] == true || o['is_favorite'] == true || o['favorite'] == true;
  }

  Future<void> setFavorite(String id, bool on) => Http.json(key, '/api/v2/galleries/$id/favorite', method: on ? 'POST' : 'DELETE');
}
