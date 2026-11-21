import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/model.dart';
import '../../core/registry.dart';
import '../../core/sites.dart';
import '../../core/source.dart';
import '../../core/sources/comic_common.dart';
import '../../core/store.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets.dart';

/// 「來源」分頁：七個網站，點進去是那個網站自己的分類、篩選
class SourcesPage extends StatelessWidget {
  const SourcesPage({super.key});

  @override
  Widget build(BuildContext context) {
    Widget group(String title, List<String> keys) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionHeader(title),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
            child: Wrap(spacing: Ui.gap, runSpacing: Ui.gap, children: [for (final k in keys) _SourceTile(src(k))]),
          ),
        ]);
    return ListView(padding: EdgeInsets.only(bottom: Ui.gutter * 2), children: [
      group('影片', Sites.videoKeys),
      group('漫畫', Sites.comicKeys),
    ]);
  }
}

class _SourceTile extends StatelessWidget {
  final Source s;
  const _SourceTile(this.s);
  @override
  Widget build(BuildContext context) {
    final color = Color(s.def.color);
    final w = Ui.tv ? 260.0 : (MediaQuery.of(context).size.width - Ui.gutter * 2 - Ui.gap) / 2;
    return SizedBox(
      width: w.clamp(140, 320),
      child: Tap(
        radius: Ui.radius,
        semanticLabel: s.label,
        onTap: () => push(context, SourcePage(s.key)),
        child: Container(
          padding: EdgeInsets.all(Ui.tv ? 22 : 16),
          decoration: BoxDecoration(
            color: C.card,
            borderRadius: BorderRadius.circular(Ui.radius),
            border: Border.all(color: C.border),
            gradient: LinearGradient(colors: [color.withValues(alpha: 0.22), C.card], begin: Alignment.topLeft, end: Alignment.bottomRight),
          ),
          child: Row(children: [
            Icon(s.isComic ? LucideIcons.bookOpen : LucideIcons.film, color: color, size: Ui.icon + 4),
            SizedBox(width: Ui.tv ? 14 : 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.body + 1, fontWeight: FontWeight.w700)),
                Text(s.sections.map((e) => e.title).join('・'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.small - 1, color: C.mutedFg)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// 一個來源：上方分頁（影片／女優／劇集…），每頁有自己的篩選
class SourcePage extends StatefulWidget {
  final String site;
  const SourcePage(this.site, {super.key});
  @override
  State<SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<SourcePage> {
  late final s = src(widget.site);

  @override
  Widget build(BuildContext context) {
    final sections = s.sections;
    return DefaultTabController(
      length: sections.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.label),
          actions: [
            if (s.isComic) _LangButton(onChanged: () => setState(() {})),
          ],
          bottom: sections.length > 1
              ? TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  indicatorColor: C.accent,
                  labelColor: C.fg,
                  unselectedLabelColor: C.mutedFg,
                  labelStyle: TextStyle(fontSize: Ui.body, fontWeight: FontWeight.w600),
                  tabs: [for (final x in sections) Tab(text: x.title)],
                )
              : null,
        ),
        body: TabBarView(children: [
          for (final x in sections)
            x.shelves ? ShelvesView(s, x.id, key: ValueKey('${x.id}${Lang.filter}')) : _SectionGrid(s, x, key: ValueKey('${x.id}${Lang.filter}')),
        ]),
      ),
    );
  }
}

class _SectionGrid extends StatefulWidget {
  final Source s;
  final Section section;
  const _SectionGrid(this.s, this.section, {super.key});
  @override
  State<_SectionGrid> createState() => _SectionGridState();
}

class _SectionGridState extends State<_SectionGrid> with AutomaticKeepAliveClientMixin {
  final values = <String, String>{};
  final _grid = GlobalKey<PagedGridState>();

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lang = Lang.filter;
    return PagedGrid(
      key: _grid,
      load: (p) => widget.s.list({'section': widget.section.id, ...values}, p),
      onTap: (it) => openItem(context, it),
      // 沒辦法請伺服器篩語言的站，在畫面這邊篩
      filter: widget.s.isComic && lang.isNotEmpty && (widget.s.key == 'jm' || widget.s.key == 'wn') ? (it) => it.lang == lang : null,
      emptyText: widget.section.id == 'fav' ? '網站帳號的收藏是空的' : '沒有內容',
      header: [
        if (widget.section.filters.isNotEmpty)
          FilterBar(
            filters: widget.section.filters,
            values: values,
            onChanged: (k, v) {
              setState(() => values[k] = v);
              _grid.currentState?.reload();
            },
          ),
      ],
    );
  }
}

/// 首頁那種一列一列的（也用在 vc 的分類一覽）
class ShelvesView extends StatelessWidget {
  final Source s;
  final String section;
  const ShelvesView(this.s, this.section, {super.key});

  @override
  Widget build(BuildContext context) => Loader<List<Shelf>>(
        load: () => s.shelves(section),
        builder: (c, shelves, reload) => RefreshIndicator(
          onRefresh: () async => reload(),
          child: ListView(padding: EdgeInsets.only(bottom: Ui.gutter * 2), children: [
            for (final sh in shelves)
              if (sh.items.isNotEmpty)
                ShelfRow(title: sh.title, items: sh.items, onTap: (it) => openItem(context, it), onMore: sh.more == null ? null : () => openLink(context, sh.more!))
              else ...[
                SectionHeader(sh.title),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final l in sh.chips)
                      Tap(
                        radius: 18,
                        onTap: () => openLink(context, l),
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: Ui.tv ? 16 : 12, vertical: Ui.tv ? 10 : 7),
                          decoration: BoxDecoration(color: C.muted, borderRadius: BorderRadius.circular(18), border: Border.all(color: C.border)),
                          child: Text(l.title, style: TextStyle(fontSize: Ui.small)),
                        ),
                      ),
                  ]),
                ),
              ],
            if (shelves.isEmpty) const EmptyView('沒有內容'),
          ]),
        ),
      );
}

/// 漫畫語言篩選（四站共用，存在設定裡）
class _LangButton extends StatelessWidget {
  final VoidCallback onChanged;
  const _LangButton({required this.onChanged});
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: '語言',
        icon: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(LucideIcons.languages),
          if (Lang.filter.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 4), child: Text(Lang.short[Lang.filter] ?? '', style: const TextStyle(color: C.accent))),
        ]),
        onPressed: () async {
          final v = await pickOption(context, '只看這個語言', [('', '全部'), ...Lang.names.entries.map((e) => (e.key, e.value))], Lang.filter);
          if (v == null) return;
          Lang.filter = v;
          Store.instance.setSetting('lang', v);
          onChanged();
        },
      );
}
