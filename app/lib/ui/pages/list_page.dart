import 'package:flutter/material.dart';

import '../../core/model.dart';
import '../../core/registry.dart';
import '../../core/sources/va.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets.dart';

/// 某個來源的一個列表（分類、標籤、女優、站內搜尋…），上面可以再篩選
class ListPage extends StatefulWidget {
  final Link link;
  const ListPage({super.key, required this.link});
  @override
  State<ListPage> createState() => _ListPageState();
}

class _ListPageState extends State<ListPage> {
  late final s = src(widget.link.src);
  late final Map<String, String> values = {};
  final _grid = GlobalKey<PagedGridState>();

  List<FilterSpec> get filters {
    final p = widget.link.params;
    if (p['q'] != null) return s.searchFilters;
    final section = s.sections.where((x) => x.id == (p['section'] ?? s.sections.first.id)).firstOrNull;
    var list = (section?.filters ?? const <FilterSpec>[]).where((f) => !p.containsKey(f.key)).toList();
    // 指定了網址（分類、標籤、女優頁）就不用再選分類
    if (p['url'] != null) list = list.where((f) => f.key != 'cat' && f.key != 'genre').toList();
    if (s.key == 'va' && p['actress'] == '1') list = [const FilterSpec('filters', '演出', VaSource.casts), ...list];
    return list;
  }

  Future<PageResult> _load(int page) {
    final p = {...widget.link.params, ...values};
    if (p['q'] != null) return s.search(p['q']!, page, p);
    return s.list(p, page);
  }

  @override
  Widget build(BuildContext context) {
    final f = filters;
    return Scaffold(
      appBar: AppBar(title: Text(widget.link.title, style: TextStyle(fontSize: Ui.body + 1))),
      body: PagedGrid(
        key: _grid,
        load: _load,
        onTap: (it) => openItem(context, it),
        header: [
          if (f.isNotEmpty)
            FilterBar(
              filters: f,
              values: values,
              onChanged: (k, v) {
                setState(() => values[k] = v);
                _grid.currentState?.reload();
              },
            ),
        ],
      ),
    );
  }
}
