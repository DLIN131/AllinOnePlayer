import 'package:html/dom.dart' as dom;

import '../model.dart';
import '../native.dart';
import '../source.dart';
import '../util.dart';

/// vb：網站沒有 API，全部從 HTML 解析（有 Cloudflare，走隱藏 WebView）。影片是直連 MP4（多畫質），要帶 Referer。
class VbSource extends Source {
  VbSource() : super('vb');

  /// 類型名稱要跟網站的查詢參數完全一致（Base64 存放）
  static final List<String> genres = b64('6KOP55WqLOazoem6teeVqixNb3Rpb24gQW5pbWUsM0RDRywyLjVELDJE5YuV55WrLEFJ55Sf5oiQLE1NRCxDb3NwbGF5').split(',');
  static const sorts = ['最新上市', '最新上傳', '本日排行', '本週排行', '本月排行', '觀看次數', '讚好比例'];

  @override
  List<Section> get sections => [
        const Section('home', '首頁', shelves: true),
        Section('browse', '分類', filters: [
          FilterSpec('genre', '類型', [('', '全部'), for (final g in genres) (g, g)]),
          FilterSpec('sort', '排序', [for (final s in sorts) (s, s)]),
        ]),
      ];

  @override
  List<FilterSpec> get searchFilters => [
        FilterSpec('genre', '類型', [('', '全部'), for (final g in genres) (g, g)]),
        FilterSpec('sort', '排序', [('', '預設'), for (final s in sorts) (s, s)]),
      ];

  String searchUrl({String query = '', String genre = '', String sort = ''}) {
    final p = [
      if (query.trim().isNotEmpty) 'query=${enc(query.trim())}',
      if (genre.isNotEmpty) 'genre=${enc(genre)}',
      if (sort.isNotEmpty) 'sort=${enc(sort)}',
    ];
    return '$base/search${p.isEmpty ? '' : '?${p.join('&')}'}';
  }

  Future<dom.Document> _doc(String url) async => parseHtml(await Http.text(key, url));

  @override
  Future<List<Shelf>> shelves(String section) async {
    final d = await _doc('/');
    final out = <Shelf>[];
    for (final header in d.querySelectorAll('a.horizontal-row-title')) {
      final h3 = header.querySelector('h3');
      final title = (h3?.nodes.whereType<dom.Text>().map((t) => t.text).join() ?? '').trim();
      // 標題後面到下一個標題之間的影片都屬於這一列
      final links = <dom.Element>[];
      var n = header.nextElementSibling;
      while (n != null && !(n.localName == 'a' && n.classes.contains('horizontal-row-title'))) {
        links.addAll(n.querySelectorAll('a[href*="watch?v="]'));
        n = n.nextElementSibling;
      }
      final items = parseCards(links);
      if (title.isEmpty || items.isEmpty) continue;
      out.add(Shelf(title, items, more: Link(key, title, {'section': 'browse', 'url': abs(header.attributes['href'], base)})));
    }
    return out;
  }

  @override
  Future<PageResult> list(Map<String, String> params, int page) async {
    final url = params['url'] ?? searchUrl(genre: params['genre'] ?? '', sort: params['sort'] ?? sorts.first);
    return _list(url, page);
  }

  Future<PageResult> _list(String url, int page) async {
    final d = await _doc('$url${url.contains('?') ? '&' : '?'}page=$page');
    final items = parseCards(d.querySelectorAll('a[href*="watch?v="]'));
    return PageResult(items, items.isNotEmpty && d.querySelector('a[href*="page=${page + 1}"]') != null);
  }

  @override
  Future<PageResult> search(String q, int page, Map<String, String> params) =>
      _list(searchUrl(query: q, genre: params['genre'] ?? '', sort: params['sort'] ?? ''), page);

  @override
  Future<Detail> detail(Item item) async {
    final d = await _doc('/watch?v=${item.id}');
    final sources = <int, String>{};
    for (final s in d.querySelectorAll('video source[src]')) {
      final src = abs(s.attributes['src'], base);
      final q = int.tryParse(s.attributes['size'] ?? '') ?? int.tryParse(RegExp(r'(\d+)p').firstMatch(src)?.group(1) ?? '');
      if (q != null) sources.putIfAbsent(q, () => src);
    }
    final qualities = sources.keys.toList()..sort((a, b) => b.compareTo(a));
    final tags = <Link>[];
    for (final a in d.querySelectorAll('.single-video-tag a[href]')) {
      final name = a.nodes.whereType<dom.Text>().map((t) => t.text).join().replaceAll(' ', ' ').trim().replaceFirst(RegExp(r'^#'), '').trim();
      if (name.isEmpty || name == 'add' || name == 'remove') continue;
      tags.add(Link(key, name, {'section': 'browse', 'url': abs(a.attributes['href'], base)}));
    }
    final infoText = d.querySelectorAll('.video-description-panel .hidden-xs').map((e) => e.text.trim()).firstWhere((t) => t.contains('觀看次數'), orElse: () => '');
    final artist = d.querySelector('#video-artist-name').txt;
    final title = d.querySelector('#shareBtn-title').txt;
    final poster = abs(d.querySelector('video[poster]')?.attributes['poster'], base);
    final docTitle = d.querySelector('title').txt.split(' - ').first.trim();
    return Detail(
      item: item,
      title: title.isNotEmpty ? title : (docTitle.isNotEmpty ? docTitle : item.title),
      cover: poster.isNotEmpty ? poster : item.cover,
      description: d.querySelector('.video-caption-text')?.text.trim() ?? '',
      info: [
        if (artist.isNotEmpty) InfoRow('作者', artist, [Link(key, artist, {'section': 'browse', 'url': searchUrl(query: artist)})]),
        if (infoText.isNotEmpty) InfoRow('資訊', infoText),
        if (qualities.isNotEmpty) InfoRow('畫質', qualities.map((q) => '${q}p').join(' / ')),
      ],
      tags: tags,
      episodes: parseCards(d.querySelectorAll('#playlist-scroll a[href*="watch?v="]')),
      episodesTitle: '播放清單',
      related: parseCards(d.querySelectorAll('#related-tabcontent a[href*="watch?v="]')),
      url: '$base/watch?v=${item.id}',
      extra: {
        'sources': [for (final q in qualities) ('${q}p', sources[q]!)],
      },
    );
  }

  @override
  Future<Stream> stream(Detail d, {Item? episode}) async {
    final det = episode != null ? await detail(episode) : d;
    final q = (det.extra['sources'] as List?)?.cast<(String, String)>() ?? const [];
    if (q.isEmpty) throw NetError('找不到播放網址（網站可能改版）');
    return Stream('mp4', q.first.$2, qualities: q, headers: {'Referer': '$base/'});
  }

  /// 把一堆指向 watch?v= 的連結整理成影片卡片（同一部的縮圖連結和標題連結會合併）
  List<Item> parseCards(List<dom.Element> links) {
    final out = <String, Item>{};
    for (final a in links) {
      final href = a.attributes['href'] ?? '';
      final i = href.indexOf('watch?v=');
      if (i < 0) continue;
      final id = RegExp(r'^[A-Za-z0-9]+').firstMatch(href.substring(i + 8))?.group(0) ?? '';
      if (id.isEmpty) continue;
      final prev = out[id];
      // 往上找包住這張卡片的容器（裡面有標題），最多 4 層
      dom.Element card = a;
      var p = a.parent;
      for (var n = 0; n < 4 && p != null; n++, p = p.parent) {
        if (p.classes.contains('video-item-container') || p.querySelector('.video-title, .title, .home-rows-videos-title') != null) {
          card = p;
          break;
        }
      }
      final img = a.querySelector('img') ?? card.querySelector('img');
      final cover = abs(img?.attributes['src'], base);
      var title = a.querySelector('.title, .home-rows-videos-title').txt;
      if (title.isEmpty) title = card.querySelector('.video-title, .title, .home-rows-videos-title').txt;
      if (title.isEmpty) title = (card.attributes['title'] ?? a.attributes['title'] ?? '').trim();
      final duration = (a.querySelector('.duration') ?? card.querySelector('.duration')).txt;
      out[id] = Item(
        src: key,
        id: id,
        title: title.isNotEmpty ? title : (prev?.title ?? ''),
        cover: cover.isNotEmpty ? cover : (prev?.cover ?? ''),
        sub: duration.isNotEmpty ? duration : (prev?.sub ?? ''),
        poster: cover.contains('/cover/') || (prev?.poster ?? false),
      );
    }
    // 廣告或沒有封面的雜訊連結就不要了
    return out.values.where((v) => v.cover.isNotEmpty || v.title.isNotEmpty).toList();
  }
}
