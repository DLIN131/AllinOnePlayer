import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/model.dart';
import '../../core/registry.dart';
import '../../core/sites.dart';
import '../../core/sources/comic_common.dart';
import '../../core/store.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets.dart';
import 'list_page.dart';

/// 搜尋：同時搜好幾個站，每站一列；漫畫也可以直接打編號或貼作品網址
class SearchPage extends StatefulWidget {
  final String initial;
  final bool comicsOnly;

  /// 在分頁裡（不是另外開的頁面）
  final bool embedded;
  const SearchPage({super.key, this.initial = '', this.comicsOnly = false, this.embedded = false});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final ctl = TextEditingController(text: widget.initial);
  late Set<String> picked;
  String query = '';
  int gen = 0;

  @override
  void initState() {
    super.initState();
    final saved = Store.instance.setting<List>('searchSites', const []).cast<String>();
    picked = widget.comicsOnly ? Sites.comicKeys.toSet() : (saved.isEmpty ? Sites.mainKeys.toSet() : saved.toSet());
    if (widget.initial.isNotEmpty) query = widget.initial;
  }

  void _submit(String q) {
    q = q.trim();
    if (q.isEmpty) return;
    Store.instance.addSearch(q);
    FocusScope.of(context).unfocus();
    // 漫畫編號 / 作品網址：只有一站時直接開作品頁
    final id = Query.parseId(q);
    if (id != null && !id.plain && id.sites.length == 1 && picked.contains(id.sites.first)) {
      openItem(context, Item(src: id.sites.first, id: id.id, title: q, cover: '', type: 'comic', poster: true));
      return;
    }
    setState(() {
      query = q;
      gen++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final field = Padding(
      padding: EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 4),
      child: TextField(
        controller: ctl,
        autofocus: !Ui.tv && widget.initial.isEmpty,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: Ui.body),
        decoration: InputDecoration(
          hintText: widget.comicsOnly ? '書名、作者、編號（JM123、#123）或作品網址' : '片名、番號、書名、作者…',
          prefixIcon: const Icon(LucideIcons.search),
          suffixIcon: IconButton(icon: const Icon(LucideIcons.x), tooltip: '清除', onPressed: () => setState(() {
                ctl.clear();
                query = '';
              })),
        ),
        onSubmitted: _submit,
      ),
    );
    final chips = SizedBox(
      height: Ui.tv ? 56 : 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: Ui.gutter, vertical: 4),
        children: [
          for (final k in widget.comicsOnly ? Sites.comicKeys : Sites.mainKeys) ...[
            FilterChip(
              label: Text(Sites.label(k), style: TextStyle(fontSize: Ui.small)),
              selected: picked.contains(k),
              showCheckmark: false,
              selectedColor: Color(Sites.def(k).color).withValues(alpha: 0.3),
              side: BorderSide(color: picked.contains(k) ? Color(Sites.def(k).color) : C.border),
              onSelected: (v) {
                setState(() {
                  v ? picked.add(k) : picked.remove(k);
                  gen++;
                });
                if (!widget.comicsOnly) Store.instance.setSetting('searchSites', picked.toList());
              },
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
    final body = query.isEmpty
        ? _history()
        : ListView(
            padding: EdgeInsets.only(bottom: Ui.gutter * 2),
            children: [
              ..._idRows(),
              for (final k in (widget.comicsOnly ? Sites.comicKeys : Sites.mainKeys))
                if (picked.contains(k)) _SiteResults(site: k, query: query, key: ValueKey('$k$gen$query')),
            ],
          );
    final content = Column(children: [field, chips, Expanded(child: body)]);
    if (widget.embedded) return SafeArea(bottom: false, child: content);
    return Scaffold(appBar: AppBar(title: const Text('搜尋')), body: content);
  }

  /// 純數字：每個漫畫站都試試這個編號
  List<Widget> _idRows() {
    final id = Query.parseId(query);
    if (id == null || !id.plain) return const [];
    final sites = id.sites.where(picked.contains).toList();
    if (sites.isEmpty) return const [];
    return [
      SectionHeader('用編號 ${id.id} 開啟'),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in sites)
            OutlinedButton(
              onPressed: () => openItem(context, Item(src: k, id: id.id, title: '${src(k).idTag(id.id)}', cover: '', type: 'comic', poster: true)),
              child: Text('${Sites.label(k)} ${src(k).idTag(id.id)}'),
            ),
        ]),
      ),
    ];
  }

  Widget _history() => Watch(Store.instance, (_) {
        final words = Store.instance.searches;
        if (words.isEmpty) return const EmptyView('輸入關鍵字開始搜尋', icon: LucideIcons.search);
        return ListView(children: [
          SectionHeader('最近搜尋', trailing: TextButton(onPressed: Store.instance.clearSearches, child: Text('清除', style: TextStyle(color: C.mutedFg, fontSize: Ui.small)))),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final w in words)
                ActionChip(
                  label: Text(w, style: TextStyle(fontSize: Ui.small)),
                  onPressed: () {
                    ctl.text = w;
                    _submit(w);
                  },
                ),
            ]),
          ),
        ]);
      });
}

class _SiteResults extends StatefulWidget {
  final String site;
  final String query;
  const _SiteResults({super.key, required this.site, required this.query});
  @override
  State<_SiteResults> createState() => _SiteResultsState();
}

class _SiteResultsState extends State<_SiteResults> with AutomaticKeepAliveClientMixin {
  late Future<PageResult> _f = src(widget.site).search(widget.query, 1, const {});

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final label = Sites.label(widget.site);
    void more() => push(context, ListPage(link: Link(widget.site, '$label：${widget.query}', {'q': widget.query})));
    return FutureBuilder<PageResult>(
      future: _f,
      builder: (c, s) {
        if (s.hasError) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionHeader(label),
            ErrorView(s.error!, compact: true, onRetry: () => setState(() => _f = src(widget.site).search(widget.query, 1, const {}))),
          ]);
        }
        if (!s.hasData) return Column(children: [SectionHeader(label), const Loading()]);
        final items = s.data!.items;
        if (items.isEmpty) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionHeader(label),
            Padding(padding: EdgeInsets.symmetric(horizontal: Ui.gutter), child: Text('找不到', style: TextStyle(color: C.mutedFg, fontSize: Ui.small))),
          ]);
        }
        return ShelfRow(title: '$label（${s.data!.total > 0 ? s.data!.total : '${items.length}${s.data!.hasMore ? '+' : ''}'}）', items: items, onTap: (it) => openItem(context, it), onMore: more);
      },
    );
  }
}
