import '../model.dart';
import '../native.dart';
import '../source.dart';
import '../util.dart';
import 'tsr.dart';

/// vc：頁面資料內嵌在 HTML 裡（見 [Tsr]），一般 HTTP 就抓得到。
/// 影片是 HLS，但清單和片段都包在 PNG 裡，播放器那邊要拆（unwrap）。分類名稱一律從網站資料來，不寫死。
class VcSource extends Source {
  VcSource() : super('vc');

  static const orders = [('createdAt', '最新發布'), ('viewCount', '最多觀看'), ('likeCount', '最多喜歡')];
  static const seriesFilters = [('all', '全部'), ('ongoing', '連載中'), ('completed', '已完結'), ('fresh', '本週更新')];
  static const seriesSorts = [('updated', '最新更新'), ('hot', '最多觀看'), ('likes', '最多喜歡'), ('most', '集數最多')];
  static const searchSorts = [('', '相關度'), ('createdAt:desc', '最新發布'), ('viewCount:desc', '最多播放'), ('likeCount:desc', '最多喜歡')];

  @override
  List<Section> get sections => const [
        Section('home', '首頁', shelves: true),
        Section('videos', '影片', filters: [FilterSpec('order', '排序', orders)]),
        Section('series', '劇集', filters: [FilterSpec('f', '狀態', seriesFilters), FilterSpec('sort', '排序', seriesSorts)]),
        Section('cats', '分類', shelves: true),
      ];

  @override
  List<FilterSpec> get searchFilters => const [
        FilterSpec('tab', '類型', [('video', '影片'), ('series', '劇集')]),
        FilterSpec('sort', '排序', searchSorts),
      ];

  Future<Map<String, Object?>> _page(String path) async {
    final html = await Http.text(key, path, headers: {'Accept-Language': 'zh-TW,zh;q=0.9'});
    return Tsr.pageData(html) ?? (throw NetError('讀不到頁面內容（網站可能改版或換網址）'));
  }

  // ---------- 欄位整理 ----------

  static String _s(Map m, String k) => (m[k] is String) ? m[k] as String : '';
  static double _n(Map m, String k) => (m[k] is num) ? (m[k] as num).toDouble() : 0;
  static List<Map> _maps(Map m, String k) => (m[k] is List) ? [for (final e in m[k] as List) if (e is Map) e] : const [];
  static List<String> _strs(Map m, String k) => (m[k] is List) ? [for (final e in m[k] as List) if (e is String) e] : const [];

  Item video(Map m) {
    final dur = _n(m, 'duration');
    final ep = m['episode'];
    return Item(
      src: key,
      id: _s(m, 'id'),
      title: _s(m, 'name'),
      cover: _s(m, 'coverImageUrl'),
      sub: [if (ep is num) '第 ${ep.toInt()} 集', if (dur > 0) fmtTime(dur)].join(' · '),
    );
  }

  Item series(Map m) {
    final count = _n(m, 'episodeCount').toInt();
    final status = switch (_s(m, 'status')) { 'COMPLETED' => '已完結', 'ONGOING' => '連載中', _ => '' };
    final ep = _s(m, 'epLabel').isNotEmpty ? _s(m, 'epLabel') : (count > 0 ? '$count 集' : '');
    return Item(
      src: key,
      id: _s(m, 'id'),
      title: _s(m, 'name'),
      cover: _s(m, 'coverImageUrl'),
      sub: [ep, status].where((e) => e.isNotEmpty).join(' · '),
      type: 'series',
      poster: m['isPoster'] == true,
    );
  }

  PageResult _paged(Map d, List<Item> items) {
    final cur = _n(d, 'pageNum') < 1 ? 1.0 : _n(d, 'pageNum');
    final pages = _n(d, 'totalPage') < 1 ? 1.0 : _n(d, 'totalPage');
    final total = d['totalVideoNum'] ?? d['total'];
    return PageResult(items, cur < pages, total: total is num ? total.toInt() : 0);
  }

  /// 網址參數；空字串、第 1 頁都省略（跟網站自己的連結一樣）
  String _qs(Map<String, Object?> p) {
    final q = p.entries.where((e) => e.value != null && e.value != '' && e.value != 1).map((e) => '${e.key}=${enc('${e.value}')}').join('&');
    return q.isEmpty ? '' : '?$q';
  }

  Link tagLink(String tag, [String order = 'createdAt']) => Link(key, tag, {'section': 'tag', 'tag': tag, 'order': order});

  // ---------- 頁面 ----------

  @override
  Future<List<Shelf>> shelves(String section) async {
    if (section == 'cats') return _cats();
    final d = await _page('/home');
    final out = <String, Shelf>{};
    Shelf? latest;
    for (final e in d.entries) {
      if (e.key.startsWith('hero')) continue; // 跟熱門劇集重複
      final maps = e.value is List ? [for (final x in e.value as List) if (x is Map) x] : const <Map>[];
      if (maps.isEmpty) continue;
      Shelf shelf;
      if (maps.first.containsKey('episodeCount')) {
        shelf = e.key.startsWith('fresh')
            ? Shelf('本週更新劇集', maps.map(series).toList(), more: Link(key, '本週更新劇集', const {'section': 'series', 'f': 'fresh'}))
            : Shelf('熱門劇集', maps.map(series).toList(), more: Link(key, '熱門劇集', const {'section': 'series', 'sort': 'hot'}));
      } else if (maps.first.containsKey('duration')) {
        final videos = maps.map(video).toList();
        if (e.key.startsWith('latest')) {
          shelf = latest = Shelf('最新影片', videos, more: Link(key, '最新影片', const {'section': 'videos'}));
        } else {
          // 分類是這一區影片最常見的第一個標籤
          final counts = <String, int>{};
          for (final m in maps) {
            final t = _strs(m, 'tags');
            if (t.isNotEmpty) counts[t.first] = (counts[t.first] ?? 0) + 1;
          }
          if (counts.isEmpty) continue;
          final tag = (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
          final hot = e.key.startsWith('hot');
          final title = hot ? '最受歡迎・$tag' : '今日熱門・$tag';
          shelf = Shelf(title, videos, more: tagLink(tag, hot ? 'likeCount' : 'createdAt'));
        }
      } else {
        continue;
      }
      out.putIfAbsent(shelf.title, () => shelf);
    }
    final list = out.values.toList();
    if (latest != null) {
      list.remove(latest);
      list.insert(0, latest);
    }
    return list;
  }

  Map<String, Object?>? _taxonomy;

  Future<Map<String, Object?>> taxonomy() async {
    if (_taxonomy != null) return _taxonomy!;
    final t = (await _page('/cat'))['taxonomy'];
    return _taxonomy = t is Map ? Map<String, Object?>.from(t) : {};
  }

  Future<List<Shelf>> _cats() async {
    final t = await taxonomy();
    final byParent = t['byParent'] is Map ? t['byParent'] as Map : const {};
    final out = <Shelf>[];
    for (final c in _maps(t, 'cats')) {
      final id = _s(c, 'id');
      final kids = byParent[id] is List ? [for (final k in byParent[id] as List) if (k is Map) _s(k, 'id')] : const <String>[];
      out.add(Shelf('$id（${_n(c, 'count').toInt()}）', const [], more: tagLink(id), chips: [tagLink(id), for (final k in kids) tagLink(k)]));
    }
    final genres = [for (final g in _maps(t, 'genre')) tagLink(_s(g, 'id'))];
    if (genres.isNotEmpty) out.add(Shelf('類型', const [], chips: genres));
    return out;
  }

  @override
  Future<PageResult> list(Map<String, String> params, int page) async {
    switch (params['section']) {
      case 'tag':
        final order = params['order'] ?? 'createdAt';
        final d = await _page('/t/${enc(params['tag'] ?? '')}${_qs({'order': order == 'createdAt' ? null : order, 'page': page})}');
        return _paged(d, _maps(d, 'videos').map(video).toList());
      case 'series':
        final f = params['f'] ?? 'all', sort = params['sort'] ?? 'updated';
        final d = await _page('/series${_qs({'f': f == 'all' ? null : f, 'sort': sort == 'updated' ? null : sort, 'tag': params['tag'], 'page': page})}');
        return _paged(d, _maps(d, 'list').map(series).toList());
      default:
        final order = params['order'] ?? 'createdAt';
        final d = await _page('/v${_qs({'order': order == 'createdAt' ? null : order, 'page': page})}');
        return _paged(d, _maps(d, 'videos').map(video).toList());
    }
  }

  @override
  Future<PageResult> search(String q, int page, Map<String, String> params) async {
    final tab = params['tab'] ?? 'video';
    final d = await _page('/search${_qs({'q': q, 't': params['cat'], 'tab': tab == 'video' ? null : tab, 'sort': params['sort'], 'page': page})}');
    if (tab == 'series') return _paged(d, _maps(d, 'seriesList').map(series).toList());
    return _paged(d, _maps(d, 'videos').map(video).toList());
  }

  @override
  Future<Detail> detail(Item item) async {
    if (item.type == 'series') {
      final d = await _page('/s/${item.id}');
      final s = d['series'] is Map ? d['series'] as Map : (throw NetError('找不到這部劇集（可能已被刪除）', 404));
      final it = series(s);
      return Detail(
        item: it,
        title: it.title,
        cover: it.cover,
        description: _s(s, 'description'),
        info: [if (it.sub.isNotEmpty) InfoRow('集數', it.sub), if (_n(s, 'viewCount') > 0) InfoRow('觀看', fmtCount(_n(s, 'viewCount')))],
        tags: [for (final t in _strs(s, 'tags')) tagLink(t)],
        episodes: _maps(d, 'episodes').map(video).toList(),
        related: _maps(d, 'more').map(series).toList(),
        url: '$base/s/${item.id}',
      );
    }
    final d = await _page('/v/${item.id}');
    final v = d['video'] is Map ? d['video'] as Map : (throw NetError('找不到這部影片（可能已被刪除）', 404));
    final it = video(v);
    final s = d['series'] is Map ? series(d['series'] as Map) : null;
    final res = _maps(v, 'sources').map((e) => _n(e, 'resolution').toInt()).fold<int>(0, (a, b) => a > b ? a : b);
    return Detail(
      item: it,
      title: it.title,
      subtitle: _s(v, 'vid'),
      cover: it.cover,
      info: [
        if (_n(v, 'duration') > 0) InfoRow('時長', fmtTime(_n(v, 'duration'))),
        if (_n(v, 'viewCount') > 0) InfoRow('觀看', fmtCount(_n(v, 'viewCount'))),
        if (_s(v, 'createdAt').isNotEmpty) InfoRow('發布', _s(v, 'createdAt').substring(0, 10)),
        if (res > 0) InfoRow('畫質', '${res}p'),
        if (s != null) InfoRow('劇集', s.title, [Link(key, s.title, {'section': 'openSeries', 'id': s.id})]),
      ],
      tags: [for (final t in _strs(v, 'tags')) tagLink(t)],
      episodes: _maps(d, 'episodes').map(video).toList(),
      related: [..._maps(d, 'relatedVideos').map(video), ..._maps(d, 'moreSeries').map(series)],
      url: '$base/v/${item.id}',
      extra: {'series': s?.toJson()},
    );
  }

  @override
  Future<Stream> stream(Detail d, {Item? episode}) async {
    final id = episode?.id ?? d.item.id;
    return Stream('hls', '$base/api/hls/$id', unwrap: true);
  }

  @override
  Map<String, String> get imageHeaders => const {};
}
