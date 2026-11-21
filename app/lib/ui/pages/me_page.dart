import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/auth.dart';
import '../../core/model.dart';
import '../../core/native.dart';
import '../../core/pin_lock.dart';
import '../../core/registry.dart';
import '../../core/sites.dart';
import '../../core/sources/comic_common.dart';
import '../../core/store.dart';
import '../../core/updater.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets.dart';
import 'pin_page.dart';

/// 「我的」：各站帳號、設定、開啟密碼、更新
class MePage extends StatefulWidget {
  const MePage({super.key});
  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  final status = <String, AuthState?>{};
  bool checking = false;

  static const accountSites = ['va', 'vb', 'nh', 'jm', 'wn', 'eh'];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh([String? only]) async {
    for (final k in accountSites) {
      if (only != null && k != only) continue;
      setState(() => status[k] = null);
      Auth.status(k).then((s) {
        if (mounted) setState(() => status[k] = s);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: EdgeInsets.fromLTRB(0, MediaQuery.of(context).padding.top, 0, Ui.gutter * 2), children: [
      SectionHeader('網站帳號', trailing: IconButton(tooltip: '重新檢查', icon: const Icon(LucideIcons.refreshCw), onPressed: _refresh)),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
        child: Text('登入都是在網站自己的登入頁（或網站的登入表單）完成，App 只記帳號名稱，不會存密碼。', style: TextStyle(color: C.mutedFg, fontSize: Ui.small - 1, height: 1.5)),
      ),
      for (final k in accountSites) _account(k),
      SectionHeader('設定'),
      _tile(LucideIcons.house, '首頁顯示的來源', _homeSummary(), _pickHome),
      _tile(LucideIcons.languages, '漫畫語言', Lang.filter.isEmpty ? '全部' : Lang.names[Lang.filter]!, () async {
        final v = await pickOption(context, '只看這個語言', [('', '全部'), ...Lang.names.entries.map((e) => (e.key, e.value))], Lang.filter);
        if (v == null) return;
        setState(() => Lang.filter = v);
        Store.instance.setSetting('lang', v);
      }),
      _tile(LucideIcons.bookOpen, '閱讀方式', Store.instance.setting<String>('readerMode', Ui.tv ? 'paged' : 'vertical') == 'paged' ? '左右翻頁' : '直向捲動', () async {
        final v = await pickOption(context, '閱讀方式', const [('vertical', '直向捲動'), ('paged', '左右翻頁')], Store.instance.setting<String>('readerMode', Ui.tv ? 'paged' : 'vertical'));
        if (v != null) setState(() => Store.instance.setSetting('readerMode', v));
      }),
      _tile(LucideIcons.lock, '開啟密碼', PinLock.enabled ? '已開啟' : '未開啟', () async {
        await push(context, const PinSettingsPage());
        setState(() {});
      }),
      _tile(LucideIcons.globe, '網站網址', '網站換網域時可以在這裡改', _editUrls),
      _tile(LucideIcons.trash2, '清除圖片快取', '封面、漫畫圖片的暫存', () async {
        await DefaultCacheManager().emptyCache();
        PaintingBinding.instance.imageCache.clear();
        if (context.mounted) toast(context, '已清除');
      }),
      SectionHeader('關於'),
      _tile(LucideIcons.info, '版本', Native.info.isDev ? '開發版' : 'v${Native.info.version}', null),
      _tile(LucideIcons.refreshCw, checking ? '檢查中…' : '檢查更新', '', checking ? null : _checkUpdate),
      _tile(LucideIcons.history, '更新紀錄', '', () => push(context, const ChangelogPage())),
    ]);
  }

  Widget _tile(IconData icon, String title, String sub, VoidCallback? onTap) => ListTile(
        contentPadding: EdgeInsets.symmetric(horizontal: Ui.gutter, vertical: Ui.tv ? 6 : 0),
        leading: Icon(icon, size: Ui.icon),
        title: Text(title, style: TextStyle(fontSize: Ui.body)),
        subtitle: sub.isEmpty ? null : Text(sub, style: TextStyle(color: C.mutedFg, fontSize: Ui.small - 1)),
        trailing: onTap == null ? null : const Icon(LucideIcons.chevronRight),
        onTap: onTap,
      );

  Widget _account(String k) {
    final s = status[k];
    final label = Sites.label(k);
    String sub;
    if (s == null) {
      sub = '檢查中…';
    } else if (s.loggedIn) {
      sub = s.name.isNotEmpty ? '已登入：${s.name}' : '已登入';
    } else if (s.expired) {
      sub = Auth.expiredText(k);
    } else if (s.error != null) {
      sub = '無法確認：${s.error}';
    } else {
      sub = '未登入';
    }
    final logged = s?.loggedIn == true;
    return Padding(
      padding: EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 0),
      child: Container(
        padding: EdgeInsets.all(Ui.tv ? 18 : 12),
        decoration: BoxDecoration(color: C.card, borderRadius: BorderRadius.circular(Ui.radius), border: Border.all(color: s?.expired == true ? C.danger : C.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(logged ? LucideIcons.circleUser : LucideIcons.user, color: logged ? C.success : C.mutedFg, size: Ui.icon),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: TextStyle(fontSize: Ui.body, fontWeight: FontWeight.w600)),
                Text(sub, style: TextStyle(fontSize: Ui.small - 1, color: s?.expired == true ? C.danger : C.mutedFg, height: 1.4)),
              ]),
            ),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!logged)
              FilledButton.icon(
                onPressed: () => _login(k),
                icon: const Icon(LucideIcons.logIn),
                label: const Text('登入'),
              ),
            if (logged)
              OutlinedButton.icon(
                onPressed: () async {
                  if (!await confirm(context, '登出 $label', '登出後網站帳號的收藏就不會顯示（本機收藏不受影響）', ok: '登出')) return;
                  await Auth.logout(k);
                  _refresh(k);
                },
                icon: const Icon(LucideIcons.logOut),
                label: const Text('登出'),
              ),
            if (k == 'jm' && logged)
              OutlinedButton(
                onPressed: () async {
                  final v = await askText(context, '帳號名稱（讀取收藏用）', initial: Auth.accountName('jm'));
                  if (v == null) return;
                  Auth.setAccountName('jm', v);
                  _refresh('jm');
                },
                child: const Text('帳號名稱'),
              ),
            if (k == 'va' && logged)
              OutlinedButton(
                onPressed: () async {
                  if (!await confirm(context, '清除網站觀看紀錄', '清除網站帳號上的所有觀看紀錄？', ok: '清除', danger: true)) return;
                  try {
                    await va.clearHistory();
                    if (mounted) toast(context, '已清除');
                  } catch (e) {
                    if (mounted) toast(context, '$e');
                  }
                },
                child: const Text('清除網站觀看紀錄'),
              ),
            if (k != 'va')
              OutlinedButton(
                onPressed: () => Native.openWeb(site: k, url: '${Sites.base(k)}/', mode: 'browse', title: label),
                child: const Text('開啟網站'),
              ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _login(String k) async {
    if (k == 'va') {
      final ok = await showDialog<bool>(context: context, builder: (_) => const _VaLoginDialog());
      if (ok == true) {
        _refresh('va');
        if (mounted) toast(context, '已登入 ${Sites.label('va')}');
      }
      return;
    }
    final s = await Auth.loginWeb(k);
    if (!mounted) return;
    setState(() => status[k] = s);
    toast(context, s.loggedIn ? '${Sites.label(k)} 已登入${s.name.isNotEmpty ? '：${s.name}' : ''}' : '${Sites.label(k)} 尚未登入');
  }

  String _homeSummary() {
    final hidden = Store.instance.setting<List>('homeHidden', const []).cast<String>();
    final shown = Sites.mainKeys.where((k) => !hidden.contains(k)).map(Sites.label);
    return shown.isEmpty ? '全部隱藏' : shown.join('、');
  }

  Future<void> _pickHome() async {
    final hidden = Store.instance.setting<List>('homeHidden', const []).cast<String>().toSet();
    await showDialog(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('首頁顯示的來源'),
          content: SizedBox(
            width: 420,
            child: ListView(shrinkWrap: true, children: [
              for (final k in Sites.mainKeys)
                CheckboxListTile(
                  value: !hidden.contains(k),
                  title: Text(Sites.label(k)),
                  onChanged: (v) => set(() => v == true ? hidden.remove(k) : hidden.add(k)),
                ),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(c), child: const Text('完成'))],
        ),
      ),
    );
    Store.instance.setSetting('homeHidden', hidden.toList());
    setState(() {});
  }

  Future<void> _editUrls() async {
    final k = await pickOption(context, '要改哪個網站的網址', [for (final k in Sites.mainKeys) (k, '${Sites.label(k)}：${Sites.base(k)}')], null);
    if (k == null || !mounted) return;
    final v = await askText(context, '${Sites.label(k)} 的網址（留空 = 預設）', initial: Sites.overrides[k] ?? '', hint: Sites.def(k).defaultBase, type: TextInputType.url);
    if (v == null) return;
    final u = v.trim();
    final m = Map<String, dynamic>.from(Store.instance.setting<Map>('siteUrls', const {}));
    if (u.isEmpty) {
      Sites.overrides.remove(k);
      m.remove(k);
    } else {
      final uri = Uri.tryParse(u.startsWith('http') ? u : 'https://$u');
      if (uri == null || uri.host.isEmpty) {
        if (mounted) toast(context, '網址格式不對');
        return;
      }
      Sites.overrides[k] = '${uri.scheme}://${uri.host}';
      m[k] = Sites.overrides[k];
    }
    Store.instance.setSetting('siteUrls', m);
    await Native.configure(Sites.nativeConfig());
    if (mounted) toast(context, '已更新 ${Sites.label(k)} 的網址');
    setState(() {});
  }

  Future<void> _checkUpdate() async {
    setState(() => checking = true);
    try {
      final r = await Updater.check(manual: true);
      if (!mounted) return;
      if (r == null) {
        toast(context, Native.info.isDev ? '開發版不會自動更新' : '已經是最新版');
      } else {
        await showUpdateDialog(context, r);
      }
    } catch (e) {
      if (mounted) toast(context, '檢查失敗：$e');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }
}

class _VaLoginDialog extends StatefulWidget {
  const _VaLoginDialog();
  @override
  State<_VaLoginDialog> createState() => _VaLoginDialogState();
}

class _VaLoginDialogState extends State<_VaLoginDialog> {
  late final email = TextEditingController(text: Auth.lastLogin('va'));
  final password = TextEditingController();
  String? error;
  bool busy = false;

  Future<void> _submit() async {
    if (email.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = '請輸入電郵和密碼');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final err = await Auth.loginVa(email.text, password.text);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        busy = false;
        error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('登入 ${Sites.label('va')}'),
        content: SizedBox(
          width: 420,
          child: AutofillGroup(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email, AutofillHints.username],
                decoration: const InputDecoration(labelText: '電郵'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: password,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(labelText: '密碼', errorText: error),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              Text('密碼只會送到網站，App 不會儲存。', style: TextStyle(color: C.mutedFg, fontSize: Ui.small - 2)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: busy ? null : _submit, child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('登入')),
        ],
      );
}

/// 有新版：顯示更新內容，按「更新」下載安裝檔
Future<void> showUpdateDialog(BuildContext context, Release r) async {
  double? progress;
  String? error;
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text('有新版本 ${r.tag}'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.title, style: TextStyle(fontSize: Ui.body, fontWeight: FontWeight.w600)),
              for (final n in r.notes) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $n', style: TextStyle(color: C.mutedFg, fontSize: Ui.small, height: 1.5))),
              if (progress != null) Padding(padding: const EdgeInsets.only(top: 16), child: LinearProgressIndicator(value: progress)),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: C.danger))),
            ]),
          ),
        ),
        actions: [
          TextButton(
            onPressed: progress != null ? null : () {
              Store.instance.setSetting('skippedVersion', r.build);
              Navigator.pop(c);
            },
            child: const Text('略過這個版本'),
          ),
          TextButton(onPressed: progress != null ? null : () => Navigator.pop(c), child: const Text('稍後')),
          FilledButton(
            autofocus: true,
            onPressed: progress != null
                ? null
                : () async {
                    set(() {
                      progress = 0;
                      error = null;
                    });
                    try {
                      await Updater.install(r, (p) => set(() => progress = p));
                      if (c.mounted) Navigator.pop(c);
                    } catch (e) {
                      set(() {
                        progress = null;
                        error = '下載失敗：$e';
                      });
                    }
                  },
            child: const Text('更新'),
          ),
        ],
      ),
    ),
  );
}

class ChangelogPage extends StatelessWidget {
  const ChangelogPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('更新紀錄')),
        body: Loader<List<Release>>(
          load: Updater.releases,
          builder: (c, list, _) => list.isEmpty
              ? const EmptyView('還沒有發布過版本')
              : ListView(padding: EdgeInsets.all(Ui.gutter), children: [
                  for (final r in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Text(r.tag, style: TextStyle(fontSize: Ui.body, fontWeight: FontWeight.w700, color: r.build == Native.info.versionCode ? C.accent : C.fg)),
                          const SizedBox(width: 8),
                          Text(r.date, style: TextStyle(color: C.mutedFg, fontSize: Ui.small - 1)),
                        ]),
                        const SizedBox(height: 4),
                        Text(r.title, style: TextStyle(fontSize: Ui.small + 1)),
                        for (final n in r.notes) Text('• $n', style: TextStyle(color: C.mutedFg, fontSize: Ui.small, height: 1.5)),
                      ]),
                    ),
                ]),
        ),
      );
}
