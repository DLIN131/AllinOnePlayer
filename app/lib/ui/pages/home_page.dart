import 'package:flutter/material.dart';

import '../../core/model.dart';
import '../../core/native.dart';
import '../../core/registry.dart';
import '../../core/sites.dart';
import '../../core/source.dart';
import '../../core/store.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets.dart';
import 'sources_page.dart';

/// 首頁：繼續觀看／閱讀，接著每個來源的最新一列（可以在「我的 › 首頁顯示」關掉某些來源）
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _gen = 0;

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    return RefreshIndicator(
      onRefresh: () async => setState(() => _gen++),
      child: Watch(store, (_) {
        final hidden = (store.setting<List>('homeHidden', const [])).cast<String>();
        final cont = store.history.where((h) => h.item.src != 'local' && (h.progress > 0.01 && h.progress < 0.97 || h.episode != null)).take(20).toList();
        return ListView(padding: EdgeInsets.only(bottom: Ui.gutter * 2), children: [
          if (cont.isNotEmpty)
            ShelfRow(
              title: '繼續觀看／閱讀',
              items: [for (final h in cont) h.item],
              showSource: true,
              progressOf: (it) => cont.firstWhere((h) => h.item.key == it.key).progress,
              onTap: (it) => openItem(context, it),
            ),
          for (final k in Sites.mainKeys)
            if (!hidden.contains(k)) _HomeShelf(src(k), key: ValueKey('$k$_gen')),
        ]);
      }),
    );
  }
}

class _HomeShelf extends StatefulWidget {
  final Source s;
  const _HomeShelf(this.s, {super.key});
  @override
  State<_HomeShelf> createState() => _HomeShelfState();
}

class _HomeShelfState extends State<_HomeShelf> with AutomaticKeepAliveClientMixin {
  Future<List<Item>>? _f;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  Future<List<Item>> _load() async {
    final grid = widget.s.sections.firstWhere((x) => !x.shelves && x.id != 'fav' && x.id != 'actresses', orElse: () => widget.s.sections.first);
    if (grid.shelves) {
      final sh = await widget.s.shelves(grid.id);
      return sh.isEmpty ? const [] : sh.first.items;
    }
    return (await widget.s.list({'section': grid.id}, 1)).items.take(24).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<Item>>(
      future: _f,
      builder: (c, snap) {
        if (snap.hasError) {
          final e = snap.error;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionHeader(widget.s.label, onMore: () => push(context, SourcePage(widget.s.key))),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
              child: ErrorView(e!, compact: true, onRetry: () => setState(() => _f = _load())),
            ),
          ]);
        }
        if (!snap.hasData) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionHeader(widget.s.label),
            SizedBox(height: Ui.wideCard * 9 / 16 + 40, child: const Loading()),
          ]);
        }
        if (snap.data!.isEmpty) return const SizedBox.shrink();
        return ShelfRow(
          title: widget.s.label,
          items: snap.data!,
          onTap: (it) => openItem(context, it),
          onMore: () => push(context, SourcePage(widget.s.key)),
        );
      },
    );
  }
}

/// 給錯誤訊息用：被擋的站
bool isBlocked(Object e) => e is BlockedError;
