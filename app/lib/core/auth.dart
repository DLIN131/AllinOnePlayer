import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import 'model.dart';
import 'native.dart';
import 'sites.dart';
import 'source.dart';
import 'sources/jm.dart';
import 'sources/va.dart';
import 'sources/vb.dart';
import 'store.dart';

/// 各站登入狀態、帳號名稱。
/// 登入方式：va 用網站自己的 JSON API（App 內表單）；漫畫四站開網站自己的登入頁（WebView），使用者在網頁上登入。
/// 不管哪種，登入狀態都是 WebView 的 cookie，App 只記帳號名稱，從不記密碼。
class Auth {
  static final _store = Store.instance;

  /// 登入狀態有變（登入、登出、過期）：畫面上的帳號清單看到就重新載入
  static final changes = StreamController<String>.broadcast();

  static String accountName(String site) => _store.account(site)['name'] as String? ?? '';

  static void setAccountName(String site, String name) {
    _store.updateAccount(site, (a) => name.trim().isEmpty ? a.remove('name') : a['name'] = name.trim());
    if (site == 'jm') JmSource.username = name.trim();
  }

  /// 上次登入時打的帳號（下次登入先幫忙填好；只記帳號）
  static String lastLogin(String site) {
    final a = _store.account(site);
    final l = a['login'] as String? ?? '';
    return l.isNotEmpty ? l : accountName(site);
  }

  static void init() {
    JmSource.username = accountName('jm');
  }

  static Future<AuthState> _check(String site) async {
    try {
      switch (site) {
        case 'va':
          final who = await VaAccount.check();
          return who == null ? const AuthState(false) : AuthState(true, name: who);
        case 'nh':
          final token = await Native.cookie(Sites.base('nh'), 'access_token');
          if (token == null) {
            final r = await Http.fetch('nh', '/auth/refresh', method: 'POST');
            if (!r.ok) return const AuthState(false);
          }
          final r = await Http.fetch('nh', '/api/v2/user');
          if (!r.ok) return AuthState(false, error: r.status == 401 ? null : Http.errorText(r));
          final j = jsonDecode(r.text) as Map;
          return AuthState(true, name: '${j['username'] ?? j['name'] ?? ''}');
        case 'jm':
          // 「我的」頁 /user/：沒登入會被導到 /login，登入後是自己的頁面
          final r = await Http.fetch('jm', '/user/');
          final loginPage = RegExp(r'/login(?:[/?#]|$)').hasMatch(r.url) || RegExp(r'<title>\s*Login\b', caseSensitive: false).hasMatch(r.text);
          if (!r.ok && !loginPage) return AuthState(false, error: Http.errorText(r));
          if (loginPage) return const AuthState(false);
          final name = accountName('jm');
          return AuthState(true, name: name.isNotEmpty ? name : _jmNameFrom(r.url, r.text));
        case 'wn':
          final r = await Http.fetch('wn', '/users.html');
          if (!r.ok) return AuthState(false, error: Http.errorText(r));
          if (r.url.contains('users-login.html') || !RegExp(r'users-logout|退出|登出').hasMatch(r.text)) return const AuthState(false);
          final m = RegExp(r'歡迎[：:,，\s]*(?:<[^>]+>)*\s*([^<\s]+)').firstMatch(r.text) ?? RegExp(r'class="[^"]*user_name[^"]*"[^>]*>\s*([^<]+)').firstMatch(r.text);
          return AuthState(true, name: m?.group(1)?.trim() ?? '');
        case 'vb':
          // 要登入的頁面：沒登入會被轉到 /login
          final r = await Http.fetch('vb', '/playlists');
          if (VbSource.isLoginPage(r.url, r.text)) return const AuthState(false);
          if (!r.ok) return AuthState(false, error: Http.errorText(r));
          return const AuthState(true);
        case 'eh':
          // 登入後論壇會在整個網域寫 ipb_member_id / ipb_pass_hash
          final id = await Native.cookie(Sites.base('eh'), 'ipb_member_id');
          if (id == null || id == '0') return const AuthState(false);
          try {
            final r = await Http.fetch('eh', Sites.forumUrl('/index.php'));
            final m = RegExp(r'Logged in as:?\s*(?:<[^>]+>\s*)*([^<]+)<', caseSensitive: false).firstMatch(r.text);
            return AuthState(true, name: m?.group(1)?.trim() ?? '');
          } catch (_) {
            return const AuthState(true);
          }
      }
      return const AuthState(false);
    } on BlockedError catch (e) {
      return AuthState(false, error: e.message);
    } on NetError catch (e) {
      return AuthState(false, error: e.message);
    } catch (e) {
      return AuthState(false, error: '$e');
    }
  }

  /// 記住「這個站登入過」。之後變成沒登入（網站那邊的登入過期了）就回 expired，
  /// 畫面才能說「登入已過期，請重新登入」，而不是只顯示空的收藏。
  static Future<AuthState> status(String site) async {
    var s = await _check(site);
    final seen = _store.account(site)['seen'] == true;
    final remembered = credSites.contains(site) && await _safe(() => Native.credHas(site), false);
    // 網站那邊的登入過期了、使用者有讓 App 記住密碼 → 在背景自動重新登入一次
    if (!s.loggedIn && s.error == null && seen && remembered && await _autoLogin(site)) s = await _check(site);
    _lastCheck[site] = DateTime.now();
    if (s.loggedIn) {
      // 備份登入 cookie：重開 App 時補回被丟掉的那些
      unawaited(_safe(() => Native.loginKeep(site), null));
    } else if (s.error == null) {
      unawaited(_safe(() => Native.loginForget(site), null));
    }
    if (s.loggedIn && !seen) _store.updateAccount(site, (a) => a['seen'] = true);
    if (s.loggedIn && s.name.isNotEmpty && site != 'jm' && accountName(site) != s.name) _store.updateAccount(site, (a) => a['name'] = s.name);
    if (site == 'jm' && s.loggedIn && s.name.isNotEmpty) JmSource.username = s.name;
    if (!s.loggedIn && s.error == null && seen) return AuthState(false, expired: true, remembered: remembered);
    return s.copyWith(remembered: remembered);
  }

  static Future<T> _safe<T>(Future<T> Function() f, T fallback) async {
    try {
      return await f();
    } catch (_) {
      return fallback;
    }
  }

  // ---------- 記住密碼、自動重新登入、保持登入 ----------

  /// 網站那邊的登入一陣子沒動就會失效的站：登入時問要不要讓 App 記住密碼（加密存在這台裝置）
  static const credSites = {'jm'};

  /// 網站那邊一陣子沒動就登出的站：App 開著時定期碰一下（jm 約半小時、vb 2 小時）
  static const keepSites = {'jm', 'vb'};

  /// 要登入才看得到的頁面（自動登入後用來確認）
  static String _checkUrl(String site) => switch (site) {
        'jm' => '${Sites.base('jm')}/user/',
        _ => '${Sites.base(site)}/',
      };

  static final _autoBusy = <String, Future<bool>>{};
  static final _autoFailedAt = <String, DateTime>{};
  static final _lastCheck = <String, DateTime>{};

  /// 同一時間只跑一次；失敗後 5 分鐘內不再試（免得一直被網站擋）
  static Future<bool> _autoLogin(String site) {
    final busy = _autoBusy[site];
    if (busy != null) return busy;
    final failed = _autoFailedAt[site];
    if (failed != null && DateTime.now().difference(failed) < const Duration(minutes: 5)) return Future.value(false);
    final f = () async {
      try {
        final ok = await Native.autoLogin(site, Sites.loginUrl(site), _checkUrl(site));
        if (!ok) _autoFailedAt[site] = DateTime.now();
        return ok;
      } catch (_) {
        _autoFailedAt[site] = DateTime.now();
        return false;
      } finally {
        _autoBusy.remove(site);
      }
    }();
    _autoBusy[site] = f;
    return f;
  }

  static Timer? _keepTimer;
  static AppLifecycleListener? _life;

  /// 保持登入：jm 這種網站那邊大約半小時沒動就登出的站，App 開著時每 10 分鐘碰一下；
  /// 開 App、從背景回來超過 10 分鐘時也檢查一次（過期了、有記住密碼就自動重新登入）。
  static void startKeepAlive() {
    void touch() {
      for (final site in keepSites) {
        if (_store.account(site)['seen'] != true) continue;
        final last = _lastCheck[site];
        if (last != null && DateTime.now().difference(last) < const Duration(minutes: 9)) continue;
        unawaited(status(site).then((_) {}, onError: (_) {}));
      }
    }

    _keepTimer?.cancel();
    _keepTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) touch();
    });
    _life ??= AppLifecycleListener(onResume: touch);
    Timer(const Duration(seconds: 4), touch);
  }

  /// 漫畫站：開網站自己的登入頁。關閉後回傳登入狀態
  static Future<AuthState> loginWeb(String site) async {
    StreamSubscription? sub;
    var checking = false;
    // 網站跳離登入頁就檢查一次，登入成功自動關掉網頁
    sub = Native.events.listen((e) async {
      if (e['type'] != 'web' || e['site'] != site || e['mode'] != 'login' || checking) return;
      final url = '${e['url']}';
      if (RegExp('login', caseSensitive: false).hasMatch(url)) return;
      checking = true;
      final s = await _check(site);
      checking = false;
      if (s.loggedIn) await Native.closeWeb();
    });
    final typed = await Native.openWeb(site: site, url: Sites.loginUrl(site), mode: 'login', title: '登入 ${Sites.label(site)}', prefill: site == 'jm' ? lastLogin('jm') : '');
    await sub.cancel();
    await Native.resetWeb(site);
    var s = await status(site);
    if (s.loggedIn && typed.isNotEmpty) {
      _store.updateAccount(site, (a) => a['login'] = typed);
      if (s.name.isEmpty) setAccountName(site, typed);
    }
    // 登入成功：已經記住過密碼的直接更新（可能換了密碼），不然讓畫面問使用者要不要記住
    if (s.loggedIn && credSites.contains(site)) {
      final ask = await _safe(() => Native.credOffer(site), false);
      s = s.copyWith(canRemember: ask);
    }
    changes.add(site);
    return s.loggedIn && s.name.isEmpty && typed.isNotEmpty ? s.copyWith(name: typed) : s;
  }

  /// va：App 內表單登入
  static Future<String?> loginVa(String email, String password) async {
    final (err, who) = await VaAccount.login(email, password);
    if (err != null) return err;
    _store.updateAccount('va', (a) {
      a['name'] = who ?? email.trim();
      a['login'] = email.trim();
      a['seen'] = true;
    });
    changes.add('va');
    return null;
  }

  static Future<void> logout(String site) async {
    if (site == 'va') {
      await VaAccount.logout();
    } else {
      if (site == 'nh') {
        try {
          await Http.fetch('nh', '/auth/logout', method: 'POST');
        } catch (_) {}
      }
      await Native.clearCookies(site);
    }
    // 自己登出：備份的登入 cookie、記住的密碼都刪掉
    await _safe(() => Native.loginForget(site), null);
    await _safe(() => Native.credForget(site), null);
    // 自己登出的就不算「過期」，帳號名稱也一起清掉；只留下次登入要預先填的帳號
    final login = _store.account(site)['login'] as String? ?? '';
    _store.setAccount(site, login.isNotEmpty ? {'login': login} : null);
    if (site == 'jm') JmSource.username = '';
    changes.add(site);
  }

  static String expiredText(String site) {
    final label = Sites.label(site);
    if (site == 'jm') return '$label 的登入已失效。這個站同一個帳號只能在一個地方保持登入，在瀏覽器或電腦版登入過就會把這裡登出，請重新登入。';
    return '$label 的登入已過期，請重新登入';
  }

  /// 從 JM「我的」頁找帳號名稱；抓不到就回空字串讓使用者自己填，不要猜
  static String _jmNameFrom(String url, String html) {
    String dec(String s) {
      try {
        return Uri.decodeComponent(s);
      } catch (_) {
        return s;
      }
    }

    final u = RegExp(r'/user/([^/?#]+)').firstMatch(url);
    if (u != null) return dec(u.group(1)!);
    final f = RegExp(r'/user/([^"/?#\s]+)/favorite').firstMatch(html);
    if (f != null) return dec(f.group(1)!);
    final menu = RegExp(r'href="(?:https?://[^/"]+)?/user/([^"/?#]+)/?"[^>]*>[\s\S]{0,200}?我的').firstMatch(html) ??
        RegExp(r'href="(?:https?://[^/"]+)?/user/([^"/?#]+)/?"[^>]*>\s*<i class="fas? fa-user-circle').firstMatch(html);
    return menu != null ? dec(menu.group(1)!) : '';
  }
}
