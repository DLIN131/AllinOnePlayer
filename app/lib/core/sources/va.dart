import 'dart:convert';

import 'package:html/dom.dart' as dom;

import '../model.dart';
import '../native.dart';
import '../source.dart';
import '../sites.dart';
import '../util.dart';

/// va：網站沒有 API，全部從 HTML 解析（有 Cloudflare，走隱藏 WebView）。播放是 HLS，CDN 要帶網站的 Referer / Origin。
class VaSource extends Source {
  VaSource() : super('va');

  /// 分類（名稱、路徑），Base64 存放
  static final List<(String, String)> categories = [
    for (final e in jsonDecode(b64(_cats)) as List) ((e as List)[0] as String, e[1] as String),
  ];
  static const _cats =
      'W1si5pyA6L+R5pu05pawIiwiL2RtNTM5L25ldyJdLFsi5paw5L2c5LiK5biCIiwiL2RtNjM1L3JlbGVhc2UiXSxbIuS4reaWh+Wtl+W5lSIsIi9kbTI3OC9jaGluZXNlLXN1YnRpdGxlIl0sWyLku4rml6XnhrHploAiLCIvZG0zMDEvdG9kYXktaG90Il0sWyLmnKzpgLHnhrHploAiLCIvZG0xNzAvd2Vla2x5LWhvdCJdLFsi5pys5pyI54ax6ZaAIiwiL2RtMjczL21vbnRobHktaG90Il0sWyLnhKHnorzmtYHlh7oiLCIvZG04MTcvdW5jZW5zb3JlZC1sZWFrIl0sWyJWUiIsIi9nZW5yZXMvVlIiXSxbIlNJUk8iLCIvZG0zNi9zaXJvIl0sWyJMVVhVIiwiL2RtMzQvbHV4dSJdLFsiR0FOQSIsIi9kbTM0L2dhbmEiXSxbIlBSRVNUSUdFIiwiL2RtMTAwNC9tYWFuIl0sWyJGQzIiLCIvZG01OTcvZmMyIl0sWyJIRVlaTyIsIi9kbTIyMDg2NDIvaGV5em8iXSxbIuadseS6rOeGsSIsIi9kbTQyL3Rva3lvaG90Il0sWyLkuIDmnKzpgZMiLCIvZG00NTUxMTc0LzFwb25kbyJdLFsiQ2FyaWJiZWFuY29tIiwiL2RtNjg0MDUyMS9jYXJpYmJlYW5jb20iXSxbIjEwbXVzdW1lIiwiL2RtNjIzODY4Mi8xMG11c3VtZSJdLFsi6bq76LGGIiwiL2RtNjMvbWFkb3UiXV0=';

  static const sorts = [
    ('', '預設'),
    ('released_at', '發行日期'),
    ('published_at', '最近更新'),
    ('saved', '收藏數'),
    ('today_views', '今日瀏覽'),
    ('weekly_views', '本週瀏覽'),
    ('monthly_views', '本月瀏覽'),
    ('views', '總瀏覽數'),
  ];

  static const casts = [('', '全部'), ('individual', '單人作品'), ('multiple', '多人作品')];

  /// 有碼／無碼：網站沒有這個參數，無碼片的番號都帶 uncensored，在 App 端過濾
  static const censors = [('', '全部'), ('c', '有碼'), ('u', '無碼')];

  @override
  List<Section> get sections => [
        Section('videos', '影片', filters: [
          FilterSpec('cat', '分類', [for (final c in categories) (c.$2, c.$1)]),
          const FilterSpec('sort', '排序', sorts),
          const FilterSpec('censor', '有碼/無碼', censors),
        ]),
        const Section('actresses', '女優'),
      ];

  @override
  List<FilterSpec> get searchFilters => const [FilterSpec('sort', '排序', sorts), FilterSpec('censor', '有碼/無碼', censors)];

  @override
  bool get hasAccount => true;

  String _withParams(String url, int page, String sort, [String filters = '']) {
    final p = [
      if (filters.isNotEmpty) 'filters=$filters',
      if (sort.isNotEmpty) 'sort=$sort',
      if (page > 1) 'page=$page',
    ];
    if (p.isEmpty) return url;
    return url + (url.contains('?') ? '&' : '?') + p.join('&');
  }

  Future<dom.Document> _doc(String url) async => parseHtml(await Http.text(key, url));

  bool _hasNext(dom.Document d, int page) => d.querySelector('a[href*="page=${page + 1}"]') != null;

  @override
  Future<PageResult> list(Map<String, String> params, int page) async {
    final section = params['section'] ?? 'videos';
    if (section == 'actresses') return _actresses(page);
    if (section == 'account') return accountList(params['path'] ?? '/saved', page);
    final url = params['url'] ?? params['cat'] ?? categories.first.$2;
    final d = await _doc(_withParams(url, page, params['sort'] ?? '', params['filters'] ?? ''));
    final items = _filter(parseCards(d), params['censor'] ?? '');
    return PageResult(items, _hasNext(d, page) && parseCards(d).isNotEmpty);
  }

  List<Item> _filter(List<Item> items, String censor) => switch (censor) {
        'c' => items.where((v) => !v.id.contains('uncensored')).toList(),
        'u' => items.where((v) => v.id.contains('uncensored')).toList(),
        _ => items,
      };

  @override
  Future<PageResult> search(String q, int page, Map<String, String> params) async {
    final d = await _doc(_withParams('/search/${enc(q.trim())}', page, params['sort'] ?? ''));
    final all = parseCards(d);
    return PageResult(_filter(all, params['censor'] ?? ''), all.isNotEmpty && _hasNext(d, page));
  }

  /// 帳號的影片收藏／觀看記錄（path = /saved 或 /history）
  Future<PageResult> accountList(String path, int page) async {
    final html = await Http.text(key, _withParams(path, page, ''));
    if (VaAccount.parseLoginEmail(html) == null) throw LoginError(key);
    final d = parseHtml(html);
    final items = parseCards(d);
    return PageResult(items, items.isNotEmpty && _hasNext(d, page));
  }

  @override
  Future<PageResult> favorites(int page) => accountList('/saved', page);

  List<Item> parseCards(dom.Document d) {
    final out = <String, Item>{};
    for (final card in d.querySelectorAll('div.thumbnail')) {
      final a = card.querySelector('a[href]');
      if (a == null) continue;
      final href = abs(a.attributes['href'], base);
      final code = href.split('/').last.split('?').first.split('#').first;
      if (code.isEmpty || out.containsKey(code)) continue;
      final img = card.querySelector('img');
      final dataSrc = img.attr('data-src');
      final cover = abs(dataSrc.isNotEmpty ? dataSrc : img.attr('src'), base);
      final t = card.querySelector('div.my-2 a')?.text.trim();
      final title = (t != null && t.isNotEmpty) ? t : img.attr('alt').trim();
      final duration = card.querySelector('span.absolute').txt;
      out[code] = Item(src: key, id: code, title: title, cover: cover, sub: duration);
    }
    return out.values.toList();
  }

  Future<PageResult> _actresses(int page) async {
    final d = await _doc(_withParams('/actresses', page, ''));
    final items = <Item>[];
    for (final li in d.querySelectorAll('li')) {
      final name = li.querySelector('h4')?.text.trim();
      final a = li.querySelector('a[href]');
      if (name == null || name.isEmpty || a == null) continue;
      items.add(Item(
        src: key,
        id: abs(a.attributes['href'], base),
        title: name,
        cover: abs(li.querySelector('img')?.attributes['src'], base),
        sub: li.querySelectorAll('p').map((p) => p.text.trim()).join(' · '),
        type: 'actress',
        poster: true,
      ));
    }
    return PageResult(items, items.isNotEmpty && _hasNext(d, page));
  }

  /// 女優頁：點女優 / 資料列的連結開這個
  Link actressLink(String name, String url) => Link(key, name, {'section': 'videos', 'url': url, 'actress': '1'});

  @override
  Future<Detail> detail(Item item) async {
    final html = await Http.text(key, '/${item.id}');
    final d = parseHtml(html);
    final rows = <InfoRow>[];
    final seen = <String>{};
    for (final div in d.querySelectorAll('div.space-y-2 > div')) {
      final text = div.text.trim();
      final i = text.indexOf(':');
      if (i <= 0) continue;
      final label = text.substring(0, i).trim();
      if (label.isEmpty || label.length > 8 || !seen.add(label)) continue;
      final links = <Link>[];
      for (final a in div.querySelectorAll('a[href]')) {
        final name = a.text.trim();
        if (name.isEmpty) continue;
        final url = abs(a.attributes['href'], base);
        links.add(Link(key, name, {'section': 'videos', 'url': url, if (url.contains('/actresses/')) 'actress': '1'}));
      }
      rows.add(InfoRow(label, text.substring(i + 1).trim(), links));
    }
    final cover = d.querySelector('meta[property="og:image"]')?.attributes['content'] ?? item.cover;
    final title = d.querySelector('h1').txt;
    final itemId = RegExp(r'/api/items/([A-Za-z0-9]+)/(?:save|view)').firstMatch(html)?.group(1);
    return Detail(
      item: Item(src: key, id: item.id, title: title.isEmpty ? item.title : title, cover: cover.replaceAll('cover-n.jpg', 'cover-t.jpg'), sub: item.sub),
      title: title.isEmpty ? item.title : title,
      subtitle: item.id.toUpperCase(),
      cover: cover,
      info: rows,
      url: '$base/${item.id}',
      extra: {'playlist': findPlaylist(html), 'itemId': itemId},
    );
  }

  /// 播放網址藏在 p,a,c,k,e,d 打包過的 JS 裡，先解開再找 m3u8
  static String? findPlaylist(String html) {
    final m3u8 = RegExp(r'''https?://[^'"\s]+?\.m3u8''');
    final packed = RegExp(r"""eval\(function\(p,a,c,k,e,d\)\{.*?\}\('(.*?)',(\d+),(\d+),'(.*?)'\.split\('\|'\)""", dotAll: true);
    for (final m in packed.allMatches(html)) {
      final p = m.group(1)!, a = int.parse(m.group(2)!), k = m.group(4)!;
      final words = k.split('|');
      final radix = a.clamp(2, 36);
      final code = p.replaceAll(r"\'", "'").replaceAllMapped(RegExp(r'\b\w+\b'), (w) {
        final i = int.tryParse(w.group(0)!, radix: radix);
        if (i != null && i < words.length && words[i].isNotEmpty) return words[i];
        return w.group(0)!;
      });
      final all = m3u8.allMatches(code).map((e) => e.group(0)!).toList();
      if (all.isNotEmpty) return all.firstWhere((u) => u.endsWith('playlist.m3u8'), orElse: () => all.first);
    }
    return m3u8.firstMatch(html)?.group(0);
  }

  @override
  Future<Stream> stream(Detail d, {Item? episode}) async {
    final url = d.extra['playlist'] as String?;
    if (url == null) throw NetError('找不到播放網址（網站可能改版）');
    return Stream('hls', url, headers: {'Referer': '$base/', 'Origin': base}, cronet: true);
  }

  // ---------- 帳號（要登入） ----------

  /// 打開影片頁時通知網站（會記一筆觀看記錄），順便拿這部有沒有收藏；沒登入回傳 null
  Future<bool?> itemView(String itemId) async {
    final r = await Http.fetch(key, '/api/items/$itemId/view', web: true, json: true);
    if (!r.ok) return null;
    try {
      final o = jsonDecode(r.text) as Map;
      if (o['user'] == null) return null;
      return o['saved'] == true;
    } catch (_) {
      return null;
    }
  }

  Future<void> setSaved(String itemId, bool saved) async {
    final r = await Http.fetch(key, '/api/items/$itemId/save', method: saved ? 'POST' : 'DELETE', body: '{}', web: true, json: true);
    if (r.status == 401) throw LoginError(key);
    if (!r.ok) throw NetError('網站回應 HTTP ${r.status}');
  }

  Future<void> clearHistory() async {
    final r = await Http.fetch(key, '/api/history', method: 'DELETE', body: '{}', web: true, json: true);
    if (r.status == 401) throw LoginError(key);
    if (!r.ok) throw NetError('網站回應 HTTP ${r.status}');
  }
}

/// va 的網站帳號：登入是網站自己的 JSON API；登入狀態就是 WebView 裡的 cookie，這裡只記帳號名稱，密碼不存
class VaAccount {
  /// 只有個人頁（收藏、觀看記錄）會有使用者選單，一般列表頁是網站快取的看不出來
  static String? parseLoginEmail(String html) {
    if (!html.contains("showDropdown = 'user'")) return null;
    final m = RegExp(r'登入為\s*</p>\s*<p[^>]*>\s*([^<]+?)\s*</p>').firstMatch(html);
    final e = m?.group(1)?.trim();
    return (e == null || e.isEmpty) ? '已登入' : e;
  }

  /// 登入；成功回傳 (null, 帳號)，失敗回傳 (原因, null)
  static Future<(String?, String?)> login(String email, String password) async {
    final body = jsonEncode({'email': email.trim(), 'password': password, 'remember': true});
    final Resp r;
    try {
      r = await Http.fetch('va', '/api/login', method: 'POST', body: body, web: true, json: true);
    } on NetError catch (e) {
      return (e.message, null);
    }
    if (r.ok) {
      try {
        final who = parseLoginEmail(await Http.text('va', '/saved'));
        if (who == null) return ('登入沒有成功，請再試一次', null);
        return (null, who);
      } catch (_) {
        return (null, email.trim());
      }
    }
    if (r.status == 422) return (_errorMessage(r.text) ?? '電郵或密碼不正確', null);
    if (r.status == 429) return ('嘗試太多次了，請稍後再試', null);
    return ('登入失敗（HTTP ${r.status}）', null);
  }

  /// 網站回的驗證錯誤：{ message, errors: { email: ["…"] } }
  static String? _errorMessage(String text) {
    try {
      final o = jsonDecode(text) as Map;
      final errors = o['errors'];
      if (errors is Map && errors.isNotEmpty) {
        final first = errors.values.first;
        if (first is List && first.isNotEmpty) return first.first.toString();
      }
      final m = o['message']?.toString();
      return (m == null || m.isEmpty) ? null : m;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> check() async {
    try {
      return parseLoginEmail(await Http.text('va', '/saved'));
    } catch (_) {
      return null;
    }
  }

  static Future<void> logout() async {
    try {
      await Http.text('va', '/logout');
    } catch (_) {}
    await Native.clearCookies('va');
  }
}

/// 用番號查女優：另一個整理女優名字的網站，沒有 Cloudflare。搜尋是模糊比對，只留番號真的對得上的結果
class VaLookup {
  static final _cache = <String, List<(String, String)>>{};

  /// 番號後面的版本標記（無碼流出、中文字幕…）拿掉，轉大寫
  static String normalize(String code) => code
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'-(uncensored-leak|chinese-subtitle|english-subtitle|uncensored|leak)$'), '')
      .toUpperCase();

  static Future<List<(String, String)>> find(String code) async {
    final q = normalize(code);
    final hit = _cache[q];
    if (hit != null) return hit;
    final html = await Http.text('vx', '${Sites.base('vx')}/?s=${Uri.encodeQueryComponent(q)}');
    return _cache[q] = parse(html, q);
  }

  /// 搜尋結果：每筆 article.archive-list，番號和女優名字在 ul.post-meta 裡
  static List<(String, String)> parse(String html, String code) {
    final q = normalize(code);
    bool matches(String t) => t == q || RegExp('^\\d+${RegExp.escape(q)}\$').hasMatch(t);
    final d = parseHtml(html);
    final out = <String, (String, String)>{};
    for (final art in d.querySelectorAll('article.archive-list')) {
      final texts = art.querySelectorAll('ul.post-meta li').map((e) => e.text.trim().toUpperCase());
      if (!texts.any(matches)) continue;
      for (final a in art.querySelectorAll('li.actress-name a')) {
        final name = a.text.trim();
        if (name.isNotEmpty) out.putIfAbsent(name, () => (name, a.attributes['href'] ?? ''));
      }
    }
    return out.values.toList();
  }
}
