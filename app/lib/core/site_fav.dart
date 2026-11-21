import 'dart:convert';

import 'model.dart';
import 'native.dart';
import 'registry.dart';
import 'sites.dart';
import 'source.dart';
import 'util.dart';

/// 網頁上的表單：送到哪、要送的欄位、可以選的收藏夾
class FavForm {
  final String action;
  final List<(String, String)> fields;
  final String? choiceName;
  final List<(String, String)> choices; // (值, 顯示名稱)
  final String? selected;
  const FavForm(this.action, this.fields, this.choiceName, this.choices, this.selected);

  List<(String, String)> body(String? choice) {
    final out = fields.where((f) => f.$1 != choiceName).toList();
    final v = choice ?? selected;
    if (choiceName != null && v != null) out.add((choiceName!, v));
    return out;
  }
}

/// 加到網站帳號的收藏。
/// nh：API；jm：網站的收藏按鈕 POST；eh、wn：打開網站自己的「加入收藏」表單（要登入才看得到），照表單欄位送出，
/// 有好幾個收藏夾時列出來讓使用者選。這樣不用猜欄位名稱，網站改版也比較不會壞。
class SiteFav {
  static FavForm? parseForm(String html, String pageUrl) {
    final doc = parseHtml(html);
    final f = doc.querySelector('form');
    if (f == null) return null;
    final base = Uri.parse(pageUrl);
    final actionAttr = f.attributes['action'] ?? '';
    final action = actionAttr.isEmpty ? pageUrl : base.resolve(actionAttr).toString();
    final fields = <(String, String)>[];
    var submitAdded = false;
    String? choiceName;
    final choices = <(String, String)>[];
    String? selected;
    String txt(String? s) => (s ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    // 收藏夾：第一組有兩個以上選項的 radio，沒有的話用第一個 select
    final radios = <String, List>{};
    for (final r in f.querySelectorAll('input[type=radio][name]')) {
      (radios[r.attributes['name']!] ??= []).add(r);
    }
    final group = radios.entries.where((e) => e.value.length > 1).firstOrNull;
    if (group != null) {
      choiceName = group.key;
      for (final r in group.value) {
        final id = r.id as String;
        String? label = id.isNotEmpty ? txt(f.querySelector('label[for="$id"]')?.text) : null;
        if (label == null || label.isEmpty) {
          var p = r.parent;
          for (var i = 0; i < 3 && p != null; i++, p = p.parent) {
            final t = txt(p.text);
            if (t.isNotEmpty) {
              label = t;
              break;
            }
          }
        }
        final v = r.attributes['value'] ?? '';
        choices.add((v, (label == null || label.isEmpty) ? v : label));
        if (r.attributes.containsKey('checked')) selected = v;
      }
    } else {
      final s = f.querySelector('select[name]');
      if (s != null) {
        choiceName = s.attributes['name'];
        for (final o in s.querySelectorAll('option')) {
          final v = (o.attributes['value'] ?? '').isEmpty ? o.text : o.attributes['value']!;
          choices.add((v, txt(o.text)));
          if (o.attributes.containsKey('selected')) selected = v;
        }
      }
    }
    selected ??= choices.isEmpty ? null : choices.first.$1;
    for (final i in f.querySelectorAll('input[name]')) {
      final name = i.attributes['name']!;
      final type = (i.attributes['type'] ?? '').toLowerCase();
      final value = i.attributes['value'] ?? '';
      switch (type) {
        case 'radio':
          if (name != choiceName && i.attributes.containsKey('checked')) fields.add((name, value));
        case 'checkbox':
          if (i.attributes.containsKey('checked')) fields.add((name, value.isEmpty ? 'on' : value));
        case 'submit':
          if (!submitAdded) {
            fields.add((name, value));
            submitAdded = true;
          }
        case 'button' || 'image' || 'reset' || 'file':
          break;
        default:
          fields.add((name, value));
      }
    }
    for (final t in f.querySelectorAll('textarea[name]')) {
      fields.add((t.attributes['name']!, t.text));
    }
    for (final s in f.querySelectorAll('select[name]')) {
      if (s.attributes['name'] == choiceName) continue;
      final o = s.querySelector('option[selected]') ?? s.querySelector('option');
      fields.add((s.attributes['name']!, o?.attributes['value'] ?? ''));
    }
    return FavForm(action, fields, choiceName, choices, selected);
  }

  static bool _isLoginPage(String html) =>
      RegExp(r'requires you to log on|login_form|ipb_login_form|users-check_login|name="login_name"', caseSensitive: false).hasMatch(html);

  static Future<FavForm> form(Detail d) async {
    final site = d.item.src;
    final String url;
    if (site == 'eh') {
      final (gid, t) = eh.split(d.item.id);
      url = '/gallerypopups.php?gid=$gid&t=$t&act=addfav';
    } else if (site == 'wn') {
      url = '/users-addfav-id-${d.item.id}.html';
    } else {
      throw NetError('這個站不用表單');
    }
    final r = await Http.fetch(site, url);
    if (!r.ok) throw NetError(Http.errorText(r), r.status);
    if (_isLoginPage(r.text)) throw LoginError(site, '還沒登入${Sites.label(site)}，登入後才能加到網站收藏');
    return parseForm(r.text, Http.full(site, url)) ?? (throw NetError('網站的收藏表單跟預期的不一樣'));
  }

  static Future<String> submit(Detail d, FavForm form, String? choice) async {
    final site = d.item.src;
    final r = await Http.fetch(site, form.action, method: 'POST', body: Http.form(form.body(choice)));
    if (!r.ok) throw NetError(Http.errorText(r), r.status);
    if (_isLoginPage(r.text)) throw LoginError(site, '還沒登入${Sites.label(site)}，登入後才能加到網站收藏');
    return _message(r.text) ?? (choice == 'favdel' ? '已從網站收藏移除' : '已加到網站收藏');
  }

  static String? _message(String text) {
    try {
      final o = jsonDecode(text);
      if (o is Map) {
        final m = '${o['msg'] ?? o['message'] ?? o['html'] ?? ''}';
        if (m.isNotEmpty) {
          final t = parseHtml(m).body?.text ?? m;
          return t.length > 80 ? t.substring(0, 80) : t;
        }
      }
    } catch (_) {}
    final t = (parseHtml(text).body?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return (t.isNotEmpty && t.length <= 60) ? t : null;
  }
}
