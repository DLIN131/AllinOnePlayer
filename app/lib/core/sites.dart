import 'util.dart';

/// 內容類型
enum Kind { video, comic }

/// 一個來源（網站）的設定。網址、站名只以 Base64 存放，原始碼裡不出現明文。
class SiteDef {
  final String key;
  final String _label;
  final String _base;
  final Kind kind;

  /// 一律走隱藏 WebView（網站有 Cloudflare）
  final bool viaWeb;

  /// 登入頁路徑（null = 沒有帳號功能或另外處理）
  final String? login;

  /// 下載檔名、編號搜尋用的前綴，例如 JM123、#123
  final String prefix;

  /// 標誌色（來源標籤）
  final int color;

  const SiteDef(this.key, this._label, this._base, this.kind, {this.viaWeb = false, this.login, this.prefix = '', required this.color});

  String get label => _label.startsWith('=') ? _label.substring(1) : b64(_label);
  String get defaultBase => b64(_base);
}

class Sites {
  static const defs = <SiteDef>[
    // 影片
    SiteDef('va', '=MPlayer', 'aHR0cHM6Ly9taXNzYXYud3M=', Kind.video, viaWeb: true, color: 0xFFE11D48),
    SiteDef('vb', '=H1', 'aHR0cHM6Ly9oYW5pbWUxLm1l', Kind.video, viaWeb: true, login: '/login', color: 0xFFF472B6),
    SiteDef('vc', '=VidHub', 'aHR0cHM6Ly9yb3V2YjEueHl6', Kind.video, color: 0xFF38BDF8),
    // 漫畫
    SiteDef('nh', 'bmhlbnRhaQ==', 'aHR0cHM6Ly9uaGVudGFpLm5ldA==', Kind.comic, login: '/login/', prefix: '#', color: 0xFFED2553),
    SiteDef('jm', '56aB5ryr5aSp5aCC', 'aHR0cHM6Ly8xOGNvbWljLnZpcA==', Kind.comic, viaWeb: true, login: '/login', prefix: 'JM', color: 0xFFFF8A00),
    SiteDef('wn', '57Sz5aOr5ryr55Wr', 'aHR0cHM6Ly93d3cud25hY2cuY29t', Kind.comic, login: '/users-login.html', prefix: 'd25hY2c=', color: 0xFF3D8BFD),
    SiteDef('eh', 'RS1IZW50YWk=', 'aHR0cHM6Ly9lLWhlbnRhaS5vcmc=', Kind.comic, login: '', color: 0xFFB5835A),
    // va 的番號女優查詢（另一個站）
    SiteDef('vx', '=lookup', 'aHR0cHM6Ly9hdi13aWtpLm5ldA==', Kind.video, color: 0xFF94A3B8),
  ];

  static final Map<String, SiteDef> byKey = {for (final d in defs) d.key: d};

  /// 使用者改過的網址（網站換網域時用）
  static final Map<String, String> overrides = {};

  static SiteDef def(String key) => byKey[key]!;
  static String label(String key) => byKey[key]?.label ?? key;
  static String base(String key) => (overrides[key] ?? def(key).defaultBase).replaceAll(RegExp(r'/+$'), '');
  static String host(String key) => Uri.parse(base(key)).host;
  static String prefix(String key) {
    final p = def(key).prefix;
    return p.endsWith('=') ? b64(p) : p;
  }

  static List<String> get videoKeys => [for (final d in defs) if (d.kind == Kind.video && d.key != 'vx') d.key];
  static List<String> get comicKeys => [for (final d in defs) if (d.kind == Kind.comic) d.key];
  static List<String> get mainKeys => [...videoKeys, ...comicKeys];

  /// EH 的帳號在論壇子網域
  static String forumUrl(String path) => base('eh').replaceFirst('://', '://forums.') + path;

  static String loginUrl(String key) => key == 'eh' ? forumUrl('/index.php?act=Login&CODE=00') : base(key) + (def(key).login ?? '/');

  /// 網址是哪個站的（含圖片 CDN 子網域）
  static String? siteForUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return null;
    for (final d in defs) {
      final root = rootDomain(Sites.host(d.key));
      if (host == root || host.endsWith('.$root')) return d.key;
    }
    return null;
  }

  static String rootDomain(String host) {
    final p = host.split('.');
    return p.length <= 2 ? host : p.sublist(p.length - 2).join('.');
  }

  /// 傳給原生層的設定
  static List<Map<String, Object?>> nativeConfig() => [
        for (final d in defs) {'key': d.key, 'base': base(d.key), 'viaWeb': d.viaWeb},
      ];
}
