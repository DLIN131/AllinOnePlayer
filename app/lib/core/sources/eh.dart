import 'package:html/dom.dart' as dom;

import '../model.dart';
import '../native.dart';
import '../sites.dart';
import '../source.dart';
import '../util.dart';
import 'comic_common.dart';

/// eh：一般網頁。編號 = gid_token（兩個都要有才能開作品頁）；列表用「next=」游標翻頁；
/// 縮圖頁只有每頁的閱讀網址，真正的圖要再開那一頁才拿得到，所以閱讀時才逐頁解析。
class EhSource extends Source {
  EhSource() : super('eh');

  static const sorts = [('latest', '最新'), ('popular', '熱門')];

  /// 列表的分類 → 沒有語言標籤時當成日文的分類
  static final _jaCats = RegExp(r'doujinshi|manga|artist cg|game cg|non-h', caseSensitive: false);
  static const _langNames = {'zh': 'chinese', 'en': 'english'};

  /// 記下每個列表第 N 頁的網址
  final _cursors = <String, Map<int, String>>{};
  final _nl = <String, String>{};

  @override
  List<Section> get sections => const [
        Section('latest', '最新', filters: [FilterSpec('sort', '排序', sorts)]),
        Section('fav', '網站收藏'),
      ];

  @override
  bool get hasAccount => true;

  (String, String) split(String id) {
    final i = id.indexOf('_');
    return i < 0 ? (id, '') : (id.substring(0, i), id.substring(i + 1));
  }

  @override
  String idTag(String id) => 'EH${split(id).$1}';

  String _withLang(String q) => [q.trim(), if (_langNames[Lang.filter] != null) 'language:${_langNames[Lang.filter]}\$'].where((e) => e.isNotEmpty).join(' ');

  List<Item> parseList(String s) {
    final doc = parseHtml(s);
    final items = <Item>[];
    final seen = <String>{};
    final re = RegExp(r'/g/(\d+)/([0-9a-f]{10})');
    for (final a in doc.querySelectorAll('a[href*="/g/"]')) {
      final m = re.firstMatch(a.attributes['href'] ?? '');
      if (m == null) continue;
      final gid = m.group(1)!;
      if (seen.contains(gid)) continue;
      final row = a.closest('tr, .gl1t');
      if (row == null) continue;
      var title = a.querySelector('.glink').txt;
      if (title.isEmpty) title = row.querySelector('.glink').txt;
      if (title.isEmpty) continue;
      seen.add(gid);
      final img = row.querySelector('img[data-src]') ?? row.querySelector('.glthumb img') ?? row.querySelector('img');
      final src = [img.attr('data-src'), img.attr('src')].firstWhere((e) => e.isNotEmpty && !e.startsWith('data:'), orElse: () => '');
      final cat = (row.querySelector('.cn') ?? row.querySelector('.cs')).txt;
      final pages = int.tryParse(RegExp(r'(\d+)\s*pages?').firstMatch(row.txt)?.group(1) ?? '');
      final langTag = row.querySelectorAll('.gt, .gtl').map((e) => e.attributes['title'] ?? '').firstWhere((t) => t.startsWith('language:') && !t.endsWith('translated'), orElse: () => '');
      var lang = Lang.detect([langTag, Lang.bracketTags(title)]);
      if (lang.isEmpty && _jaCats.hasMatch(cat)) lang = 'ja';
      items.add(Item(
        src: key,
        id: '${gid}_${m.group(2)}',
        title: title,
        cover: abs(src, base),
        sub: [cat, if (pages != null) '$pages 頁'].where((e) => e.isNotEmpty).join('・'),
        type: 'comic',
        poster: true,
        lang: lang,
      ));
    }
    return items;
  }

  String? nextUrl(String s) {
    final h = parseHtml(s).querySelector('a#dnext, a#unext')?.attributes['href'];
    return (h == null || h.isEmpty) ? null : h;
  }

  Future<PageResult> _listPage(String first, int page) async {
    final String url;
    if (page > 1) {
      final u = _cursors[first]?[page];
      if (u == null) return PageResult.empty;
      url = u;
    } else {
      url = first;
    }
    final s = await Http.text(key, url);
    final next = nextUrl(s);
    if (next != null) (_cursors[first] ??= {})[page + 1] = next;
    return PageResult(parseList(s), next != null);
  }

  @override
  Future<PageResult> list(Map<String, String> params, int page) async {
    if (params['section'] == 'fav') return favorites(page);
    if (params['q'] != null) return search(params['q']!, page, params);
    if (params['sort'] == 'popular') return page > 1 ? PageResult.empty : PageResult(parseList(await Http.text(key, '/popular')), false);
    final q = _withLang('');
    return _listPage(q.isNotEmpty ? '/?f_search=${enc(q)}' : '/', page);
  }

  @override
  Future<PageResult> search(String q, int page, Map<String, String> params) => _listPage('/?f_search=${enc(_withLang(q))}', page);

  @override
  Future<Detail> detail(Item it) async {
    final (gid, token) = split(it.id);
    if (token.isEmpty) throw NetError('需要完整的作品網址（含 token）');
    final url = '/g/$gid/$token/';
    var s = await Http.text(key, url);
    // 有些作品先出「內容警告」頁，帶 nw=always 才會進去
    if (parseHtml(s).querySelector('#gn') == null && s.contains('nw=always')) s = await Http.text(key, '$url?nw=always');
    return parseDetail(it.id, s);
  }

  static const _nsName = {
    'language': '語言', 'parody': '原作', 'character': '角色', 'group': '社團', 'artist': '作者', 'cosplayer': 'Coser',
    'male': '標籤', 'female': '標籤', 'mixed': '標籤', 'other': '標籤', 'reclass': '分類',
  };

  Detail parseDetail(String id, String s) {
    final doc = parseHtml(s);
    final (gid, token) = split(id);
    if (doc.querySelector('#gn') == null) {
      final msg = (doc.querySelector('.d p') ?? doc.querySelector('p')).txt;
      throw NetError(msg.isEmpty ? '找不到（可能已被刪除）' : msg, 404);
    }
    final tags = <(String, String, String, String)>[]; // (label, name, query, ns)
    for (final tr in doc.querySelectorAll('#taglist tr')) {
      final ns = tr.querySelector('.tc').txt.replaceFirst(RegExp(r':$'), '');
      for (final a in tr.querySelectorAll('a')) {
        final name = a.txt;
        tags.add((_nsName[ns] ?? ns, ['male', 'female', 'mixed'].contains(ns) ? '${ns[0]}:$name' : name, '$ns:"$name\$"', ns));
      }
    }
    const order = ['作者', '社團', '原作', '角色', '語言', '標籤'];
    int rank(String l) => order.contains(l) ? order.indexOf(l) : 99;
    tags.sort((a, b) => rank(a.$1).compareTo(rank(b.$1)));
    final info = <InfoRow>[InfoRow('編號', gid)];
    const zh = {'Posted': '上傳', 'File Size': '大小', 'Length': '頁數', 'Favorited': '收藏數'};
    for (final tr in doc.querySelectorAll('#gdd tr')) {
      final k = tr.querySelector('.gdt1').txt.replaceFirst(RegExp(r':$'), '');
      final v = tr.querySelector('.gdt2').txt;
      if (zh[k] != null) info.add(InfoRow(zh[k]!, v.replaceFirst(RegExp(r'\s*pages?$'), '').replaceFirst(RegExp(r'\s*times$'), '')));
    }
    final pages = int.tryParse(RegExp(r'(\d+)\s*pages?').firstMatch(doc.querySelector('#gdd').txt)?.group(1) ?? '');
    final cover = RegExp(r'url\(([^)]+)\)').firstMatch(doc.querySelector('#gd1 div')?.attributes['style'] ?? '')?.group(1) ?? '';
    final langNames = tags.where((t) => t.$4 == 'language' && t.$2 != 'translated').map((t) => t.$2).join(' ');
    final title = doc.querySelector('#gn').txt;
    var lang = Lang.detect([langNames, Lang.bracketTags(title)]);
    if (lang.isEmpty && langNames.isEmpty) lang = 'ja';
    return Detail(
      item: Item(src: key, id: '${gid}_$token', title: title, cover: cover, type: 'comic', poster: true, lang: lang, sub: pages != null ? '$pages 頁' : ''),
      title: title,
      subtitle: doc.querySelector('#gj').txt,
      cover: cover,
      tags: [for (final t in tags) Link(key, '${t.$1}：${t.$2}', {'q': t.$3})],
      lang: lang,
      info: info,
      pages: pages,
      url: '$base/g/$gid/$token/',
      extra: {'firstHtml': s, 'siteFav': favFolder(doc)},
    );
  }

  /// 作品頁右邊的收藏連結：沒收藏是「Add to Favorites」，收藏了會顯示收藏夾名稱
  String? favFolder(dom.Document doc) {
    final t = doc.querySelector('#favoritelink').txt;
    return (t.isNotEmpty && !t.toLowerCase().contains('add to favorites')) ? t : null;
  }

  List<String> pageLinks(String s) => parseHtml(s).querySelectorAll('#gdt a[href*="/s/"]').map((a) => a.attributes['href'] ?? '').where((e) => e.isNotEmpty).toList();

  @override
  Future<List<ComicPage>> read(Detail d, String? chapterId) async {
    final (gid, token) = split(d.item.id);
    final first = pageLinks((d.extra['firstHtml'] as String?) ?? await Http.text(key, '/g/$gid/$token/'));
    final perPage = first.isEmpty ? 1 : first.length;
    final total = d.pages ?? first.length;
    final rest = [for (var p = 1; p * perPage < total; p++) p];
    final more = <String>[];
    for (var i = 0; i < rest.length; i += 4) {
      final batch = rest.sublist(i, (i + 4).clamp(0, rest.length));
      final got = await Future.wait([for (final p in batch) Http.text(key, '/g/$gid/$token/?p=$p').then(pageLinks)]);
      more.addAll(got.expand((e) => e));
    }
    final all = {...first, ...more}.toList();
    if (all.isEmpty) throw NetError('找不到圖片');
    return [for (final sp in all) ComicPage('', resolve: (retry) => resolve(sp, retry))];
  }

  /// 開閱讀頁拿圖片網址；retry 時帶 nl 參數換一台圖片伺服器
  Future<String> resolve(String spage, bool retry) async {
    var url = spage;
    if (retry && _nl[spage] != null) url += '${url.contains('?') ? '&' : '?'}nl=${_nl[spage]}';
    final s = await Http.text(key, url);
    final (src, n) = parseImagePage(s);
    if (n != null) _nl[spage] = n;
    if (src == null) throw NetError(RegExp('limit', caseSensitive: false).hasMatch(s) ? '已達網站的圖片瀏覽上限，請稍後再試或登入' : '找不到圖片');
    return src;
  }

  (String?, String?) parseImagePage(String s) {
    final src = RegExp(r'<img id="img" src="([^"]+)"').firstMatch(s)?.group(1);
    return (src == null ? null : unescapeHtml(src), RegExp(r"nl\('([^']+)'\)").firstMatch(s)?.group(1));
  }

  @override
  Future<PageResult> favorites(int page) async {
    final r = await _listPage('/favorites.php', page);
    return r;
  }

  @override
  Map<String, String> get imageHeaders => {'Referer': '$base/'};

  static String forum(String path) => Sites.forumUrl(path);
}
