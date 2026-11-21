import 'dart:async';
import 'dart:convert';

import 'model.dart';
import 'native.dart';
import 'sites.dart';
import 'source.dart';
import 'sources/jm.dart';
import 'sources/va.dart';
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
    final s = await _check(site);
    if (s.loggedIn && _store.account(site)['seen'] != true) _store.updateAccount(site, (a) => a['seen'] = true);
    if (s.loggedIn && s.name.isNotEmpty && site != 'jm' && accountName(site) != s.name) _store.updateAccount(site, (a) => a['name'] = s.name);
    if (site == 'jm' && s.loggedIn && s.name.isNotEmpty) JmSource.username = s.name;
    if (!s.loggedIn && s.error == null && _store.account(site)['seen'] == true) return const AuthState(false, expired: true);
    return s;
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
    final s = await status(site);
    if (s.loggedIn && typed.isNotEmpty) {
      _store.updateAccount(site, (a) => a['login'] = typed);
      if (s.name.isEmpty) setAccountName(site, typed);
    }
    changes.add(site);
    return s.loggedIn && s.name.isEmpty && typed.isNotEmpty ? AuthState(true, name: typed) : s;
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
