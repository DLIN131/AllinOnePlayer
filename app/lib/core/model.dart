// 七個來源的資料都轉成同一種格式，畫面那邊不用管是哪個站。

/// 列表裡的一個項目
class Item {
  final String src;
  final String id;
  final String title;
  final String cover;

  /// 副標：時長、頁數、集數…
  final String sub;

  /// video | series | comic | actress
  final String type;

  /// 直式封面（海報、漫畫）
  final bool poster;

  /// 漫畫語言（zh / en / ja / ''）
  final String lang;

  const Item({
    required this.src,
    required this.id,
    required this.title,
    required this.cover,
    this.sub = '',
    this.type = 'video',
    this.poster = false,
    this.lang = '',
  });

  String get key => '${src}_$id';

  Map<String, Object?> toJson() => {
        'src': src,
        'id': id,
        'title': title,
        'cover': cover,
        'sub': sub,
        'type': type,
        'poster': poster,
        'lang': lang,
      };

  factory Item.fromJson(Map j) => Item(
        src: j['src'] ?? j['site'] ?? '',
        id: '${j['id'] ?? ''}',
        title: j['title'] ?? '',
        cover: j['cover'] ?? '',
        sub: j['sub'] ?? '',
        type: j['type'] ?? 'video',
        poster: j['poster'] == true,
        lang: j['lang'] ?? '',
      );

  Item copyWith({String? title, String? cover, String? sub}) =>
      Item(src: src, id: id, title: title ?? this.title, cover: cover ?? this.cover, sub: sub ?? this.sub, type: type, poster: poster, lang: lang);

  @override
  bool operator ==(Object other) => other is Item && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

class PageResult {
  final List<Item> items;
  final bool hasMore;
  final int total;
  const PageResult(this.items, this.hasMore, {this.total = 0});
  static const empty = PageResult([], false);
}

/// 點了會開某個來源的列表（分類、標籤、女優、搜尋…）
class Link {
  final String src;
  final String title;
  final Map<String, String> params;
  const Link(this.src, this.title, this.params);
}

/// 首頁的一列
class Shelf {
  final String title;
  final List<Item> items;
  final Link? more;

  /// 沒有作品、只有一排分類按鈕的列
  final List<Link> chips;
  const Shelf(this.title, this.items, {this.more, this.chips = const []});
}

/// 列表上方的一組篩選
class FilterSpec {
  final String key;
  final String label;
  final List<(String, String)> options; // (值, 顯示名稱)
  const FilterSpec(this.key, this.label, this.options);
  String get defaultValue => options.first.$1;
}

/// 來源的一個分頁（例如「影片」「女優」「劇集」）
class Section {
  final String id;
  final String title;

  /// grid：分頁列表；shelves：首頁那種一列一列
  final bool shelves;
  final List<FilterSpec> filters;
  const Section(this.id, this.title, {this.shelves = false, this.filters = const []});
}

class InfoRow {
  final String label;
  final String text;
  final List<Link> links;
  const InfoRow(this.label, this.text, [this.links = const []]);
}

class Chapter {
  final String id;
  final String title;
  const Chapter(this.id, this.title);
}

/// 閱讀頁的一張圖。segs > 0：切條打亂的圖要重組；resolve != null：要再開一頁才拿得到圖片網址
class ComicPage {
  final String url;
  final int segs;
  final int width;
  final int height;
  final Future<String> Function(bool retry)? resolve;
  const ComicPage(this.url, {this.segs = 0, this.width = 0, this.height = 0, this.resolve});
}

/// 作品頁
class Detail {
  final Item item;
  final String title;
  final String subtitle;
  final String cover;
  final String description;
  final List<InfoRow> info;
  final List<Link> tags;
  final List<Item> related;

  /// 影片：同一部劇的各集；漫畫：章節在 chapters
  final List<Item> episodes;
  final String episodesTitle;
  final List<Chapter> chapters;
  final int? pages;
  final String url;
  final String lang;

  /// 各站自己的東西（播放來源、網站內部編號、作品頁 HTML…）
  final Map<String, Object?> extra;

  const Detail({
    required this.item,
    required this.title,
    this.subtitle = '',
    required this.cover,
    this.description = '',
    this.info = const [],
    this.tags = const [],
    this.related = const [],
    this.episodes = const [],
    this.episodesTitle = '選集',
    this.chapters = const [],
    this.pages,
    this.url = '',
    this.lang = '',
    this.extra = const {},
  });
}

/// 播放一部影片要給播放器的東西
class Stream {
  /// hls / mp4 / local
  final String kind;
  final String url;

  /// 多畫質 MP4：(顯示名稱, 網址)，高到低
  final List<(String, String)> qualities;
  final Map<String, String> headers;
  final bool cronet;
  final bool unwrap;
  const Stream(this.kind, this.url, {this.qualities = const [], this.headers = const {}, this.cronet = false, this.unwrap = false});

  Map<String, Object?> get conn => {'headers': headers, 'cronet': cronet, 'unwrap': unwrap};
}

/// 長按封面的預覽要播什麼（靜音）
class Preview {
  final String kind;
  final String url;
  final Map<String, Object?> conn;

  /// 播的是正片：在幾個時間點之間跳著播
  final bool montage;

  /// 這個播不了時改播的（例如預覽短片不存在 → 正片）
  final Future<Preview> Function()? fallback;
  const Preview(this.kind, this.url, {this.conn = const {}, this.montage = false, this.fallback});
}

/// 網站帳號狀態
class AuthState {
  final bool loggedIn;
  final String name;
  final String? error;
  final bool expired;

  /// 使用者讓 App 記住了密碼（登入失效時自動重新登入）
  final bool remembered;

  /// 剛剛登入成功，可以問使用者要不要記住密碼
  final bool canRemember;
  const AuthState(this.loggedIn, {this.name = '', this.error, this.expired = false, this.remembered = false, this.canRemember = false});

  AuthState copyWith({bool? expired, bool? remembered, bool? canRemember, String? name}) => AuthState(loggedIn,
      name: name ?? this.name, error: error, expired: expired ?? this.expired, remembered: remembered ?? this.remembered, canRemember: canRemember ?? this.canRemember);
}
