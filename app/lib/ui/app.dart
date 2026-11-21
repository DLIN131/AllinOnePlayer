import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/native.dart';
import '../core/pin_lock.dart';
import '../core/updater.dart';
import 'pages/home_page.dart';
import 'pages/library_page.dart';
import 'pages/me_page.dart';
import 'pages/pin_page.dart';
import 'pages/search_page.dart';
import 'pages/sources_page.dart';
import 'theme.dart';

class AioApp extends StatelessWidget {
  const AioApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AllinOnePlayer',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        darkTheme: buildTheme(),
        themeMode: ThemeMode.dark,
        home: const Root(),
      );
}

/// 開啟密碼：開 App 時、離開超過 60 秒回來時要輸入
class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  bool locked = PinLock.enabled;
  DateTime? _hiddenAt;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onHide: () => _hiddenAt = DateTime.now(),
      onShow: () {
        final t = _hiddenAt;
        _hiddenAt = null;
        if (PinLock.enabled && t != null && DateTime.now().difference(t).inSeconds >= 60) setState(() => locked = true);
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _checkUpdate() async {
    if (Native.info.isDev) return;
    await Future.delayed(const Duration(seconds: 3));
    try {
      final r = await Updater.check();
      if (r != null && mounted) {
        // 解鎖後再跳
        while (locked && mounted) {
          await Future.delayed(const Duration(seconds: 1));
        }
        if (mounted) await showUpdateDialog(context, r);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        const Shell(),
        if (locked) Positioned.fill(child: PinGate(onUnlocked: () => setState(() => locked = false))),
      ]);
}

class _Tab {
  final String label;
  final IconData icon;
  final Widget page;
  const _Tab(this.label, this.icon, this.page);
}

/// 手機：底部 5 個分頁；電視：左側選單
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int index = 0;
  final _visited = <int>{0};

  static final tabs = [
    const _Tab('首頁', LucideIcons.house, HomePage()),
    const _Tab('來源', LucideIcons.compass, SourcesPage()),
    const _Tab('搜尋', LucideIcons.search, SearchPage(embedded: true)),
    const _Tab('收藏', LucideIcons.library, LibraryPage()),
    const _Tab('我的', LucideIcons.circleUser, MePage()),
  ];

  void _go(int i) => setState(() {
        index = i;
        _visited.add(i);
      });

  @override
  Widget build(BuildContext context) {
    // 還沒點過的分頁不建立（不用一開 App 就載入全部）
    final stack = IndexedStack(index: index, children: [
      for (var i = 0; i < tabs.length; i++) _visited.contains(i) ? tabs[i].page : const SizedBox.shrink(),
    ]);
    if (Ui.tv) {
      return Scaffold(
        body: Row(children: [
          FocusTraversalGroup(
            child: Container(
              width: 196,
              color: C.card,
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 16, 24),
                  child: Row(children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(LucideIcons.play, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(child: Text('AllinOne', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
                  ]),
                ),
                for (var i = 0; i < tabs.length; i++) _RailItem(tabs[i], selected: i == index, autofocus: i == 0, onTap: () => _go(i)),
              ]),
            ),
          ),
          Expanded(child: FocusTraversalGroup(child: stack)),
        ]),
      );
    }
    return Scaffold(
      body: SafeArea(bottom: false, child: stack),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: _go,
        destinations: [for (final t in tabs) NavigationDestination(icon: Icon(t.icon), label: t.label)],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  final _Tab tab;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;
  const _RailItem(this.tab, {required this.selected, required this.onTap, this.autofocus = false});
  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            autofocus: widget.autofocus,
            borderRadius: BorderRadius.circular(12),
            // 遙控器移到選單項目上就切換分頁（不用按 OK）
            onFocusChange: (f) {
              setState(() => focused = f);
              if (f && !widget.selected) widget.onTap();
            },
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: Ui.dur(context, 120),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: widget.selected ? C.accent.withValues(alpha: 0.18) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: focused ? C.ring : Colors.transparent, width: 3),
              ),
              child: Row(children: [
                Icon(widget.tab.icon, color: widget.selected ? C.accent : C.mutedFg, size: 22),
                const SizedBox(width: 14),
                Text(widget.tab.label, style: TextStyle(fontSize: 17, fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500, color: widget.selected ? C.fg : C.mutedFg)),
              ]),
            ),
          ),
        ),
      );
}
