import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../model.dart';
import '../native.dart';
import '../sites.dart';
import '../source.dart';
import '../util.dart';
import 'comic_common.dart';

/// jm：網頁，有 Cloudflare，走隱藏 WebView。閱讀頁的圖被橫切成好幾條上下倒置，要重組（見 [segments]）
class JmSource extends Source {
  JmSource() : super('jm');

  static const sorts = [('mr', '最新'), ('mv', '最多觀看'), ('tf', '最多喜歡'), ('mp', '最多圖片')];
  static const _langTag = {'zh': '中文', 'en': '英文', 'ja': '日文'};

  /// 收藏網址要帳號名稱（登入時記下，或使用者自己填）
  static String username = '';

  @override
  List<Section> get sections => const [
        Section('latest', '最新', filters: [FilterSpec('sort', '排序', sorts)]),
        Section('fav', '網站收藏'),
      ];

  @override
  List<FilterSpec> get searchFilters => const [FilterSpec('sort', '排序', sorts)];

  @override
  bool get hasAccount => true;

  PageResult parseList(String s, int page) {
    final doc = parseHtml(s);
    final seen = <String>{};
    final items = <Item>[];
    for (final a in doc.querySelectorAll('a[href*="/album/"]')) {
      final m = RegExp(r'/album/(\d+)').firstMatch(a.attributes['href'] ?? '');
      if (m == null) continue;
      final img = a.querySelector('img');
      if (img == null) continue;
      final src = [img.attr('data-original'), img.attr('data-src'), img.attr('src')].firstWhere((e) => e.isNotEmpty && !e.contains('blank.'), orElse: () => '');
      // 選單、廣告裡也有連到作品的圖示，只收封面在 /media/albums/ 的
      final id = m.group(1)!;
      if (!src.contains('/media/albums/') || !seen.add(id)) continue;
      final box = a.closest('.list-col, .well, .p-b-15') ?? a.parent?.parent;
      final cat = [box?.querySelector('.label-category').txt ?? '', box?.querySelector('.label-sub').txt ?? ''].where((e) => e.isNotEmpty).join('・');
      var title = box?.querySelector('.video-title').txt ?? '';
      if (title.isEmpty) title = img.attr('title');
      if (title.isEmpty) title = img.attr('alt');
      if (title.isEmpty) title = 'JM$id';
      final tagText = box?.querySelectorAll('a.tag').map((e) => e.txt).join(' ') ?? '';
      items.add(Item(src: key, id: id, title: title, cover: abs(src, base), sub: cat, type: 'comic', poster: true, lang: Lang.detect([tagText, cat, Lang.bracketTags(title)])));
    }
    final hasMore = doc.querySelector('.pagination a[href*="page=${page + 1}"]') != null;
    return PageResult(items, hasMore);
  }

  @override
  Future<PageResult> list(Map<String, String> params, int page) async {
    if (params['section'] == 'fav') return favorites(page);
    if (params['q'] != null) return search(params['q']!, page, params);
    final sort = params['sort'] ?? 'mr';
    // 有語言篩選時改搜該語言標籤，不然英日文的本子很少出現在最新列表
    if (Lang.filter.isNotEmpty) return search('', page, {'sort': sort});
    return parseList(await Http.text(key, '/albums?o=$sort&page=$page'), page);
  }

  @override
  Future<PageResult> search(String q, int page, Map<String, String> params) async {
    var query = q.trim();
    final tag = _langTag[Lang.filter];
    // 站內語法「+A +B」= 兩個都要有；使用者自己有用語法的就不動
    if (tag != null) query = query.isEmpty ? tag : (RegExp(r'[\s+-]').hasMatch(query) ? query : '+$query +$tag');
    return parseList(await Http.text(key, '/search/photos?search_query=${enc(query)}&o=${params['sort'] ?? 'mr'}&page=$page'), page);
  }

  static const _typeName = {'works': '作品', 'actor': '角色', 'tags': '標籤', 'author': '作者'};

  @override
  Future<Detail> detail(Item it) async => parseDetail(it.id, await Http.text(key, '/album/${it.id}/'));

  Detail parseDetail(String id, String s) {
    final doc = parseHtml(s);
    final tags = <(String, String, String)>[]; // (type, label, name)
    for (final span in doc.querySelectorAll('span[data-type]')) {
      final type = span.attributes['data-type'] ?? '';
      for (final a in span.querySelectorAll('a[class*="web-"]')) {
        final name = a.txt;
        if (name.isNotEmpty && !tags.any((t) => t.$3 == name && t.$1 == type)) tags.add((type, _typeName[type] ?? type, name));
      }
    }
    final order = _typeName.keys.toList();
    tags.sort((a, b) => order.indexOf(a.$1).compareTo(order.indexOf(b.$1)));
    final chapters = <Chapter>[];
    final dup = RegExp(r'^(第\s*\d+\s*話)\s+(.*?)\s*\1$');
    for (final a in doc.querySelectorAll('.episode a[href*="/photo/"]')) {
      final m = RegExp(r'/photo/(\d+)').firstMatch(a.attributes['href'] ?? '');
      if (m == null) continue;
      final cid = m.group(1)!;
      if (chapters.any((c) => c.id == cid)) continue;
      // 標題常是「第1話 書名 第1話」，把尾巴重複的話數拿掉
      var t = a.querySelector('h3, li').txt;
      if (t.isEmpty) t = a.txt;
      t = t.replaceAllMapped(dup, (m) => '${m.group(1)} ${m.group(2)}');
      chapters.add(Chapter(cid, t));
    }
    final pageCount = RegExp(r'\d+').firstMatch(doc.querySelector('.pagecount').txt)?.group(0);
    final date = doc.querySelector('[itemprop=datePublished]')?.attributes['content'] ?? '';
    final cover = doc.querySelector('img[src*="/media/albums/$id"]')?.attributes['src'];
    var title = doc.querySelector('#book-name, h1').txt;
    if (title.isEmpty) title = 'JM$id';
    final lang = Lang.detect([tags.where((t) => t.$1 == 'tags').map((t) => t.$3).join(' '), Lang.bracketTags(title)]);
    return Detail(
      item: Item(src: key, id: id, title: title, cover: abs(cover, base), type: 'comic', poster: true, lang: lang, sub: pageCount != null ? '$pageCount 頁' : ''),
      title: title,
      cover: abs(cover, base),
      tags: [for (final t in tags) Link(key, '${t.$2}：${t.$3}', {'q': t.$3})],
      lang: lang,
      info: [
        InfoRow('編號', 'JM$id'),
        InfoRow('頁數', pageCount ?? '-'),
        InfoRow('上架', date.isEmpty ? '-' : date),
        InfoRow('章節', chapters.isNotEmpty ? '${chapters.length} 話' : '單本'),
      ],
      chapters: chapters,
      pages: int.tryParse(pageCount ?? ''),
      related: parseList(s, 1).items.where((e) => e.id != id).take(18).toList(),
      url: '$base/album/$id/',
    );
  }

  @override
  Future<List<ComicPage>> read(Detail d, String? chapterId) async => parseReader(chapterId ?? d.item.id, await Http.text(key, '/photo/${chapterId ?? d.item.id}'));

  List<ComicPage> parseReader(String id, String s) {
    final aid = int.tryParse(RegExp(r'var aid = (\d+);').firstMatch(s)?.group(1) ?? '') ?? int.parse(id);
    final scramble = int.tryParse(RegExp(r'var scramble_id = (\d+);').firstMatch(s)?.group(1) ?? '') ?? 220980;
    var files = <String>[];
    try {
      final arr = RegExp(r'var page_arr = (\[[^\]]*\]);').firstMatch(s)?.group(1) ?? '[]';
      files = [for (final f in jsonDecode(arr) as List) '$f'];
    } catch (_) {}
    final urls = <String, String>{};
    for (final m in RegExp('data-original="([^"]*/media/photos/$aid/([^"?/]+)[^"]*)"').allMatches(s)) {
      urls.putIfAbsent(m.group(2)!, () => m.group(1)!);
    }
    if (files.isEmpty) files = urls.keys.toList();
    final firstUrl = urls.values.isEmpty ? '' : urls.values.first.replaceAll(RegExp(r'/media/photos/.*$'), '');
    final cdn = firstUrl.isNotEmpty ? firstUrl : base.replaceFirst('//', '//cdn-msp.');
    if (files.isEmpty) throw NetError('找不到圖片');
    return [
      for (final f in files)
        ComicPage(urls[f] ?? '$cdn/media/photos/$aid/$f', segs: f.endsWith('.gif') ? 0 : segments(scramble, aid, f.contains('.') ? f.substring(0, f.lastIndexOf('.')) : f)),
    ];
  }

  /// 每張要切幾段由編號和檔名的 md5 決定
  static int segments(int scrambleId, int aid, String file) {
    if (aid < scrambleId) return 0;
    if (aid < 268850) return 10;
    final x = aid < 421926 ? 10 : 8;
    final h = md5.convert(utf8.encode('$aid$file')).toString();
    return (h.codeUnitAt(h.length - 1) % x) * 2 + 2;
  }

  @override
  Future<PageResult> favorites(int page) async {
    if (username.isEmpty) throw LoginError(key, '已登入，但讀不到帳號名稱。請到「我的」頁的帳號設定填寫你的帳號名稱，就能讀取收藏');
    final s = await Http.text(key, '/user/${enc(username)}/favorite/albums?page=$page');
    final r = parseList(s, page);
    // 第一頁就空的時候說清楚是哪個原因，不要只顯示空白
    if (page == 1 && r.items.isEmpty) {
      final title = parseHtml(s).querySelector('title').txt;
      if (RegExp(r'^login\b', caseSensitive: false).hasMatch(title)) throw LoginError(key, '登入已失效，請到「我的」頁重新登入');
      throw NetError('帳號「$username」的收藏是空的。如果網站上明明有收藏，可能是帳號名稱不對，請到「我的」頁確認或修改');
    }
    return r;
  }

  /// 網站的收藏按鈕：POST /ajax/favorite_album（album_id、fid＝收藏夾，0 是預設）
  Future<String> addFavorite(String id) async {
    final r = await Http.fetch(key, '/ajax/favorite_album', method: 'POST', body: Http.form([('album_id', id), ('fid', '0')]), web: true);
    if (!r.ok) throw NetError(Http.errorText(r), r.status);
    Map? o;
    try {
      o = jsonDecode(r.text) as Map;
    } catch (_) {}
    if (o == null) throw NetError(r.text.toLowerCase().contains('login') ? '還沒登入${Sites.label(key)}' : '網站回應看不懂');
    final msg = '${o['msg'] ?? o['message'] ?? ''}';
    if ((o['status'] ?? 1) != 1) throw NetError(msg.isEmpty ? '收藏失敗' : msg);
    return msg.isEmpty ? '已加到網站收藏' : msg;
  }
}
