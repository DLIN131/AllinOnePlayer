import '../model.dart';
import '../native.dart';
import '../sites.dart';
import '../source.dart';
import '../util.dart';
import 'comic_common.dart';

/// wn：一般網頁
class WnSource extends Source {
  WnSource() : super('wn');

  /// 分類編號 → 語言（同人誌／單行本／雜誌／韓漫 各自分漢化、日語、English）
  static const _cateLang = {1: 'zh', 9: 'zh', 10: 'zh', 20: 'zh', 12: 'ja', 13: 'ja', 14: 'ja', 16: 'en', 17: 'en', 18: 'en'};

  @override
  List<Section> get sections => const [Section('latest', '最新'), Section('fav', '網站收藏')];

  @override
  bool get hasAccount => true;

  PageResult parseList(String s, int page) {
    final doc = parseHtml(s);
    final seen = <String>{};
    final items = <Item>[];
    for (final a in doc.querySelectorAll('a[href*="photos-index-aid-"]')) {
      final m = RegExp(r'aid-(\d+)').firstMatch(a.attributes['href'] ?? '');
      final img = a.querySelector('img');
      if (m == null || img == null) continue;
      final id = m.group(1)!;
      if (!seen.add(id)) continue;
      final box = a.closest('li') ?? a.parent?.parent;
      final info = box?.querySelector('.info_col').txt ?? '';
      final pages = int.tryParse(RegExp(r'(\d+)\s*張').firstMatch(info)?.group(1) ?? '');
      var title = a.attr('title');
      if (title.isEmpty) title = img.attr('alt');
      if (title.isEmpty) title = box?.querySelector('.title').txt ?? '';
      if (title.isEmpty) title = '#$id';
      final cateEl = box?.querySelector('[class*="cate-"]');
      final cate = int.tryParse(RegExp(r'cate-(\d+)').firstMatch(cateEl?.className ?? '')?.group(1) ?? '');
      final src = img.attr('data-original').isNotEmpty ? img.attr('data-original') : img.attr('src');
      items.add(Item(
        src: key,
        id: id,
        title: title,
        cover: abs(src, base),
        sub: pages != null ? '$pages 頁' : '',
        type: 'comic',
        poster: true,
        lang: _cateLang[cate] ?? Lang.detect([Lang.bracketTags(title)]),
      ));
    }
    final pager = doc.querySelector('.paginator, .f_left.paginator');
    final next = RegExp('(page-|p=)${page + 1}\\b');
    final hasMore = pager != null && pager.querySelectorAll('a').any((a) => RegExp(r'後頁|下一頁|>').hasMatch(a.txt) || next.hasMatch(a.attributes['href'] ?? ''));
    return PageResult(items, hasMore);
  }

  @override
  Future<PageResult> list(Map<String, String> params, int page) async {
    if (params['section'] == 'fav') return favorites(page);
    if (params['q'] != null) return search(params['q']!, page, params);
    if (Lang.filter.isEmpty) return parseList(await Http.text(key, '/albums-index-page-$page.html'), page);
    // 有語言篩選時，把該語言的幾個分類各抓一頁合起來，依編號（新到舊）排
    final cates = _cateLang.entries.where((e) => e.value == Lang.filter).map((e) => e.key);
    final pages = await Future.wait([for (final c in cates) Http.text(key, '/albums-index-page-$page-cate-$c.html').then((s) => parseList(s, page))]);
    final items = pages.expand((p) => p.items).toList()..sort((a, b) => (int.tryParse(b.id) ?? 0).compareTo(int.tryParse(a.id) ?? 0));
    return PageResult(items, pages.any((p) => p.hasMore));
  }

  @override
  Future<PageResult> search(String q, int page, Map<String, String> params) async =>
      parseList(await Http.text(key, '/search/index.php?q=${enc(q)}&m=&syn=yes&f=_all&s=create_time_DESC&p=$page'), page);

  @override
  Future<Detail> detail(Item it) async => parseDetail(it.id, await Http.text(key, '/photos-index-aid-${it.id}.html'));

  Detail parseDetail(String id, String s) {
    final doc = parseHtml(s);
    // 不存在的編號網站一樣回 200，只是沒有封面和標題
    final coverImg = doc.querySelector('.uwthumb img') ?? (throw NetError('找不到（可能已被刪除）', 404));
    final labels = doc.querySelectorAll('.uwconn label').map((e) => e.txt).where((e) => e.isNotEmpty);
    final info = <InfoRow>[InfoRow('編號', '${Sites.prefix(key)}$id')];
    int? pages;
    for (final l in labels) {
      final parts = l.split(RegExp(r'[：:]'));
      if (parts.length < 2) continue;
      final k = parts[0].trim();
      final v = parts.sublist(1).join(':').trim();
      if (k.contains('頁數')) pages = int.tryParse(RegExp(r'\d+').firstMatch(v)?.group(0) ?? '');
      if (!k.contains('編號')) info.add(InfoRow(k, v));
    }
    final tags = [for (final a in doc.querySelectorAll('a.tagshow')) Link(key, '標籤：${a.txt}', {'q': a.txt})];
    final category = info.firstWhere((r) => r.label.contains('分類'), orElse: () => const InfoRow('', '')).text;
    final intro = doc.querySelector('.uwconn p').txt.replaceFirst(RegExp(r'^簡介[：:]\s*'), '');
    var title = doc.querySelector('#bodywrap h2, h2').txt;
    if (title.isEmpty) title = '#$id';
    final lang = Lang.detect([category, Lang.bracketTags(title)]);
    final cover = abs(coverImg.attributes['src'], base);
    return Detail(
      item: Item(src: key, id: id, title: title, cover: cover, type: 'comic', poster: true, lang: lang, sub: pages != null ? '$pages 頁' : ''),
      title: title,
      cover: cover,
      description: intro,
      tags: tags,
      lang: lang,
      info: info,
      pages: pages,
      related: parseList(s, 1).items.where((e) => e.id != id).take(18).toList(),
      url: '$base/photos-index-aid-$id.html',
    );
  }

  @override
  Future<List<ComicPage>> read(Detail d, String? chapterId) async => parseReader(await Http.text(key, '/photos-gallery-aid-${d.item.id}.html'));

  List<ComicPage> parseReader(String js) {
    final re = RegExp(r'url:\s*fast_img_host\+\\?"([^"\\]+)\\?",\s*caption:\s*\\?"([^"\\]*)');
    final list = <(String, String)>[];
    for (final m in re.allMatches(js)) {
      final u = m.group(1)!, cap = m.group(2)!;
      // 最後一張是站方的「加入收藏」宣傳圖
      if (RegExp(r'/(themes|static)/').hasMatch(u) || cap.contains('收藏')) continue;
      list.add((abs(u, base), cap));
    }
    int? num(String c) => int.tryParse(RegExp(r'\d+').firstMatch(c)?.group(0) ?? '');
    if (list.every((e) => num(e.$2) != null)) list.sort((a, b) => num(a.$2)!.compareTo(num(b.$2)!));
    if (list.isEmpty) throw NetError('找不到圖片');
    return [for (final e in list) ComicPage(e.$1)];
  }

  @override
  Future<PageResult> favorites(int page) async {
    final s = await Http.text(key, '/users-users_fav-page-$page.html');
    if (RegExp(r'users-login|login_name', caseSensitive: false).hasMatch(s) && !s.contains('users-logout')) throw LoginError(key, '還沒登入${Sites.label(key)}');
    return parseList(s, page);
  }
}
