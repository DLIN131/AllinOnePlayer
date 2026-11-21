import 'dart:convert';

import 'model.dart';
import 'native.dart';
import 'sites.dart';

/// 一般請求：狀態碼不是 2xx 就丟出看得懂的錯誤
class Http {
  static String full(String site, String path) => path.startsWith('http') ? path : Sites.base(site) + path;

  static Future<Resp> fetch(String site, String path, {String method = 'GET', String? body, String? contentType, Map<String, String>? headers, bool web = false, bool json = false}) =>
      Native.fetch(site, full(site, path), method: method, body: body, contentType: contentType, headers: headers, web: web, json: json);

  static Future<String> text(String site, String path, {Map<String, String>? headers}) async {
    final r = await fetch(site, path, headers: headers);
    if (!r.ok) throw NetError(errorText(r), r.status);
    return r.text;
  }

  static Future<Map<String, dynamic>> json(String site, String path, {String method = 'GET'}) async {
    final r = await fetch(site, path, method: method);
    if (!r.ok) throw NetError(errorText(r), r.status);
    final t = r.text.trim();
    return t.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(t) as Map);
  }

  static String form(List<(String, String)> fields) => fields.map((f) => '${Uri.encodeQueryComponent(f.$1)}=${Uri.encodeQueryComponent(f.$2)}').join('&');

  static String errorText(Resp r) {
    if (r.status == 404) return '找不到（可能已被刪除）';
    if (r.status == 429) return '請求太頻繁，稍等一下再試';
    try {
      final j = jsonDecode(r.text);
      if (j is Map) {
        final m = (j['error'] ?? j['detail'] ?? j['message'])?.toString();
        if (m != null && m.isNotEmpty) return m;
      }
    } catch (_) {}
    return '載入失敗（HTTP ${r.status}）';
  }
}

/// 一個來源（網站）。網站改版時要改的就是各來源的檔案。
abstract class Source {
  final String key;
  Source(this.key);

  SiteDef get def => Sites.def(key);
  String get label => def.label;
  Kind get kind => def.kind;
  String get base => Sites.base(key);
  bool get isComic => kind == Kind.comic;

  /// 來源頁的分頁（第一個是預設）
  List<Section> get sections;

  /// shelves 類型的分頁
  Future<List<Shelf>> shelves(String section) async => const [];

  /// 列表：params 至少有 section，其餘是篩選值或 Link 帶的參數
  Future<PageResult> list(Map<String, String> params, int page);

  List<FilterSpec> get searchFilters => const [];

  Future<PageResult> search(String q, int page, Map<String, String> params);

  Future<Detail> detail(Item item);

  /// 影片：播放來源；episode = 劇集裡的某一集
  Future<Stream> stream(Detail d, {Item? episode}) => throw UnimplementedError();

  /// 長按封面的預覽：預設播正片（最低畫質、靜音），在幾個時間點之間跳著播
  Future<Preview> preview(Item item) async {
    final d = await detail(item);
    final s = await stream(d);
    final url = s.qualities.isNotEmpty ? s.qualities.last.$2 : s.url;
    return Preview(s.kind, url, conn: s.conn, montage: true);
  }

  /// 漫畫：閱讀頁的圖
  Future<List<ComicPage>> read(Detail d, String? chapterId) => throw UnimplementedError();

  /// 有網站帳號（登入）
  bool get hasAccount => false;

  /// 網站帳號的收藏
  Future<PageResult> favorites(int page) async => PageResult.empty;

  /// 圖片要帶的標頭（CDN 看 Referer）
  Map<String, String> get imageHeaders => {'Referer': '$base/'};

  /// 下載檔名裡的編號，例如 JM123、#123
  String idTag(String id) => Sites.prefix(key) + id;
}
