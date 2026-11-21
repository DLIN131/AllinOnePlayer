import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/auth.dart';
import '../../core/comic/comic_downloads.dart';
import '../../core/comic/library.dart';
import '../../core/model.dart';
import '../../core/native.dart';
import '../../core/playback.dart';
import '../../core/registry.dart';
import '../../core/sites.dart';
import '../../core/store.dart';
import '../../core/util.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets.dart';
import 'list_page.dart';
import 'reader_page.dart';

/// 「收藏」分頁：本機收藏、紀錄、網站帳號的收藏、下載、書櫃
class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tabs = ['收藏', '紀錄', '網站收藏', if (!Ui.tv) '下載', '書櫃'];
    return DefaultTabController(
      length: tabs.length,
      child: Column(children: [
        SafeArea(
          bottom: false,
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            indicatorColor: C.accent,
            labelColor: C.fg,
            unselectedLabelColor: C.mutedFg,
            labelStyle: TextStyle(fontSize: Ui.body, fontWeight: FontWeight.w600),
            padding: EdgeInsets.symmetric(horizontal: Ui.gutter - 12),
            tabs: [for (final t in tabs) Tab(text: t)],
          ),
        ),
        Expanded(
          child: TabBarView(children: [
            const _Favorites(),
            const _History(),
            const _SiteFavorites(),
            if (!Ui.tv) const _Downloads(),
            const ShelfView(),
          ]),
        ),
      ]),
    );
  }
}

/// 影片／漫畫切換
class _KindSwitch extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _KindSwitch(this.value, this.onChanged);
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(Ui.gutter, 10, Ui.gutter, 4),
        child: SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [ButtonSegment(value: '', label: Text('全部')), ButtonSegment(value: 'video', label: Text('影片')), ButtonSegment(value: 'comic', label: Text('漫畫'))],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}

bool _kindOk(Item it, String kind) => kind.isEmpty || (kind == 'comic') == (it.type == 'comic');

class _Favorites extends StatefulWidget {
  const _Favorites();
  @override
  State<_Favorites> createState() => _FavoritesState();
}

class _FavoritesState extends State<_Favorites> {
  String kind = '';
  @override
  Widget build(BuildContext context) => Watch(Store.instance, (_) {
        final items = Store.instance.favorites.where((e) => _kindOk(e, kind)).toList();
        return Column(children: [
          _KindSwitch(kind, (v) => setState(() => kind = v)),
          Expanded(
            child: items.isEmpty
                ? const EmptyView('還沒有收藏。在作品頁按「收藏」就會出現在這裡', icon: LucideIcons.heart)
                : _Grid(items, longPressLabel: '移除收藏', onLongPress: (it) async {
                    if (await confirm(context, '移除收藏', it.title, ok: '移除')) Store.instance.setFavorite(it, false);
                  }),
          ),
        ]);
      });
}

class _Grid extends StatelessWidget {
  final List<Item> items;
  final void Function(Item)? onLongPress;
  final double Function(Item)? progressOf;

  /// 影片長按是預覽，onLongPress 變成預覽框裡的按鈕
  final String? longPressLabel;
  const _Grid(this.items, {this.onLongPress, this.progressOf, this.longPressLabel});

  /// 影片（橫式）和漫畫（直式）分開排，格子比例才會一致
  @override
  Widget build(BuildContext context) {
    final videos = items.where((e) => !e.poster).toList();
    final posters = items.where((e) => e.poster).toList();
    final mixed = videos.isNotEmpty && posters.isNotEmpty;
    return CustomScrollView(slivers: [
      if (videos.isNotEmpty) ...[
        if (mixed) SliverToBoxAdapter(child: SectionHeader('影片（${videos.length}）')),
        _sliver(context, videos, false),
      ],
      if (posters.isNotEmpty) ...[
        if (mixed) SliverToBoxAdapter(child: SectionHeader('漫畫・劇集（${posters.length}）')),
        _sliver(context, posters, true),
      ],
      SliverToBoxAdapter(child: SizedBox(height: Ui.gutter * 2)),
    ]);
  }

  Widget _sliver(BuildContext context, List<Item> list, bool poster) {
    final w = poster ? Ui.posterCard : Ui.wideCard;
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 8),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: w + 12,
          mainAxisSpacing: Ui.gap,
          crossAxisSpacing: Ui.gap,
          childAspectRatio: poster ? (w / (w * 1.5 + (Ui.tv ? 80 : 58))) : (w / (w * 9 / 16 + (Ui.tv ? 72 : 52))),
        ),
        delegate: SliverChildBuilderDelegate(
          (c, i) => ItemCard(list[i],
              width: double.infinity,
              poster: poster,
              showSource: true,
              progress: progressOf?.call(list[i]) ?? 0,
              onTap: () => openItem(context, list[i]),
              longPressLabel: longPressLabel,
              onLongPress: onLongPress == null ? null : () => onLongPress!(list[i])),
          childCount: list.length,
        ),
      ),
    );
  }
}

class _History extends StatefulWidget {
  const _History();
  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  String kind = '';
  @override
  Widget build(BuildContext context) => Watch(Store.instance, (_) {
        final list = Store.instance.history.where((h) => _kindOk(h.item, kind)).toList();
        return Column(children: [
          Row(children: [
            Expanded(child: _KindSwitch(kind, (v) => setState(() => kind = v))),
            Padding(
              padding: EdgeInsets.only(right: Ui.gutter - 8),
              child: IconButton(
                tooltip: '清除紀錄',
                icon: const Icon(LucideIcons.trash2),
                onPressed: () async {
                  if (await confirm(context, '清除紀錄', kind.isEmpty ? '清除全部觀看／閱讀紀錄？' : '清除全部${kind == 'comic' ? '閱讀' : '觀看'}紀錄？', ok: '清除', danger: true)) {
                    Store.instance.clearHistory(comics: kind.isEmpty ? null : kind == 'comic');
                  }
                },
              ),
            ),
          ]),
          Expanded(
            child: list.isEmpty
                ? const EmptyView('還沒有紀錄', icon: LucideIcons.history)
                : _Grid([for (final h in list) h.item], progressOf: (it) => list.firstWhere((h) => h.item.key == it.key).progress, longPressLabel: '刪除紀錄', onLongPress: (it) async {
                    if (await confirm(context, '刪除這筆紀錄', it.title, ok: '刪除')) Store.instance.removeHistory(it.key);
                  }),
          ),
        ]);
      });
}

/// 網站帳號的收藏：只列出已登入的站
class _SiteFavorites extends StatefulWidget {
  const _SiteFavorites();
  @override
  State<_SiteFavorites> createState() => _SiteFavoritesState();
}

class _SiteFavoritesState extends State<_SiteFavorites> {
  @override
  Widget build(BuildContext context) => StreamBuilder(
        stream: Auth.changes.stream,
        builder: (c, _) {
          final sites = [for (final k in Sites.mainKeys) if (src(k).hasAccount && (Store.instance.account(k)['seen'] == true || Auth.accountName(k).isNotEmpty)) k];
          if (sites.isEmpty) return const EmptyView('還沒有登入任何網站。到「我的」登入後，網站帳號的收藏會出現在這裡', icon: LucideIcons.bookmark);
          return ListView(padding: EdgeInsets.only(bottom: Ui.gutter * 2), children: [
            for (final k in sites) ...[
              _AccountShelf(k, k == 'va' ? '/saved' : null),
              if (k == 'va') _AccountShelf(k, '/history'),
            ],
          ]);
        },
      );
}

class _AccountShelf extends StatefulWidget {
  final String site;
  final String? vaPath;
  const _AccountShelf(this.site, this.vaPath);
  @override
  State<_AccountShelf> createState() => _AccountShelfState();
}

class _AccountShelfState extends State<_AccountShelf> {
  late Future<PageResult> _f = _load();

  Future<PageResult> _load() => widget.vaPath != null ? va.accountList(widget.vaPath!, 1) : src(widget.site).favorites(1);

  String get title => '${Sites.label(widget.site)}${widget.vaPath == '/history' ? ' 觀看紀錄' : ' 收藏'}';

  Link get link => widget.vaPath != null ? Link(widget.site, title, {'section': 'account', 'path': widget.vaPath!}) : Link(widget.site, title, const {'section': 'fav'});

  @override
  Widget build(BuildContext context) => FutureBuilder<PageResult>(
        future: _f,
        builder: (c, s) {
          if (s.hasError) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SectionHeader(title),
              ErrorView(s.error!, compact: true, onRetry: () => setState(() => _f = _load())),
            ]);
          }
          if (!s.hasData) return Column(children: [SectionHeader(title), const Loading()]);
          if (s.data!.items.isEmpty) {
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SectionHeader(title),
              Padding(padding: EdgeInsets.symmetric(horizontal: Ui.gutter), child: Text('是空的', style: TextStyle(color: C.mutedFg, fontSize: Ui.small))),
            ]);
          }
          return ShelfRow(title: title, items: s.data!.items, onTap: (it) => openItem(context, it), onMore: () => push(context, ListPage(link: link)));
        },
      );
}

// ---------- 下載（手機） ----------

class _Downloads extends StatelessWidget {
  const _Downloads();

  @override
  Widget build(BuildContext context) => Watch(Listenable.merge([VideoDownloads.instance, ComicDownloads.instance]), (_) {
        final videos = VideoDownloads.instance.items;
        final comics = ComicDownloads.instance.jobs;
        if (videos.isEmpty && comics.isEmpty) return const EmptyView('還沒有下載。在作品頁按「下載」', icon: LucideIcons.download);
        return ListView(padding: EdgeInsets.only(bottom: Ui.gutter * 2), children: [
          if (videos.isNotEmpty) SectionHeader('影片（${videos.length}）'),
          for (final v in videos) _VideoRow(v),
          if (comics.isNotEmpty) SectionHeader('漫畫（${comics.length}）'),
          for (final j in comics) _ComicRow(j),
        ]);
      });
}

String _statusText(String status, String error, double progress) => switch (status) {
      'running' => '下載中 ${(progress * 100).toStringAsFixed(0)}%',
      'queued' => '排隊中',
      'paused' => '已暫停 ${(progress * 100).toStringAsFixed(0)}%',
      'failed' => '失敗：$error',
      _ => '已完成',
    };

class _VideoRow extends StatelessWidget {
  final Map v;
  const _VideoRow(this.v);
  @override
  Widget build(BuildContext context) {
    final meta = Map.from(v['meta'] as Map? ?? const {});
    final item = Item.fromJson(meta);
    final status = '${v['status']}';
    final progress = (v['progress'] as num?)?.toDouble() ?? 0;
    final key = '${v['key']}';
    final localCover = '${v['cover'] ?? ''}';
    return ListTile(
      leading: SizedBox(width: 96, child: AspectRatio(aspectRatio: 16 / 9, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Cover(localCover.isNotEmpty ? localCover : item.cover, site: item.src)))),
      title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.small)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_statusText(status, '${v['error'] ?? ''}', progress)}  ·  ${fmtSize((v['bytes'] as num?) ?? 0)}${'${v['quality']}'.isNotEmpty ? '  ·  ${v['quality']}' : ''}',
            style: TextStyle(fontSize: Ui.small - 2, color: status == 'failed' ? C.danger : C.mutedFg)),
        if (status != 'done') LinearProgressIndicator(value: progress, minHeight: 3),
      ]),
      onTap: status == 'done' ? () => Playback.playLocal(item, '${v['file']}') : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (status == 'running' || status == 'queued') IconButton(tooltip: '暫停', icon: const Icon(LucideIcons.pause), onPressed: () => Native.pauseDownload(key)),
        if (status == 'paused' || status == 'failed') IconButton(tooltip: '繼續', icon: const Icon(LucideIcons.play), onPressed: () => Native.resumeDownload(key)),
        IconButton(
          tooltip: '刪除',
          icon: const Icon(LucideIcons.trash2),
          onPressed: () async {
            if (await confirm(context, '刪除下載', '刪除「${item.title}」和已下載的檔案？', ok: '刪除', danger: true)) Native.deleteDownload(key);
          },
        ),
      ]),
    );
  }
}

class _ComicRow extends StatelessWidget {
  final ComicJob j;
  const _ComicRow(this.j);
  @override
  Widget build(BuildContext context) {
    final dl = ComicDownloads.instance;
    return ListTile(
      leading: SizedBox(width: 52, child: AspectRatio(aspectRatio: 2 / 3, child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Cover(j.item.cover, site: j.item.src)))),
      title: Text(j.item.title + (j.chapterTitle.isEmpty ? '' : '　${j.chapterTitle}'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.small)),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_statusText(j.status, j.error, j.progress)}${j.total > 0 ? '  ·  ${j.done} / ${j.total} 頁' : ''}', style: TextStyle(fontSize: Ui.small - 2, color: j.status == 'failed' ? C.danger : C.mutedFg)),
        if (j.status != 'done') LinearProgressIndicator(value: j.progress, minHeight: 3),
      ]),
      onTap: j.status == 'done'
          ? () async {
              await Library.instance.refresh();
              final b = Library.instance.books.where((b) => b.path == j.file).firstOrNull;
              if (b != null && context.mounted) push(context, ReaderPage.book(b));
            }
          : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (j.status == 'running' || j.status == 'queued') IconButton(tooltip: '暫停', icon: const Icon(LucideIcons.pause), onPressed: () => dl.pause(j.id)),
        if (j.status == 'paused' || j.status == 'failed') IconButton(tooltip: '繼續', icon: const Icon(LucideIcons.play), onPressed: () => dl.resume(j.id)),
        IconButton(
          tooltip: '移除',
          icon: const Icon(LucideIcons.trash2),
          onPressed: () async {
            final del = j.status == 'done' ? await confirm(context, '移除下載紀錄', '要連漫畫檔一起刪除嗎？（不刪的話書櫃裡還看得到）', ok: '連檔案一起刪', danger: true) : true;
            await dl.remove(j.id, deleteFile: del || j.status != 'done');
            Library.instance.refresh();
          },
        ),
      ]),
    );
  }
}

// ---------- 書櫃 ----------

/// 本機漫畫檔＋合集
class ShelfView extends StatefulWidget {
  const ShelfView({super.key});
  @override
  State<ShelfView> createState() => _ShelfViewState();
}

class _ShelfViewState extends State<ShelfView> {
  final lib = Library.instance;
  String q = '';

  @override
  void initState() {
    super.initState();
    lib.refresh();
  }

  @override
  Widget build(BuildContext context) => Watch(lib, (_) {
        final cols = lib.collections;
        final inCol = {for (final c in cols) ...c.files};
        final books = lib.books.where((b) => !inCol.contains(b.name) && (q.isEmpty || b.title.toLowerCase().contains(q.toLowerCase()))).toList();
        return CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(Ui.gutter, 10, Ui.gutter, 4),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(hintText: '找書名', prefixIcon: Icon(LucideIcons.search), isDense: true),
                    onChanged: (v) => setState(() => q = v),
                  ),
                ),
                const SizedBox(width: 8),
                if (!Ui.tv)
                  IconButton(
                    tooltip: '加入手機裡的漫畫檔',
                    icon: const Icon(LucideIcons.folderOpen),
                    onPressed: () async {
                      // cbz 沒有通用的檔案類型，Android 上用副檔名篩會選不到，選完再篩
                      final r = await FilePicker.pickFiles(type: FileType.any);
                      final re = RegExp(r'\.(cbz|zip)$', caseSensitive: false);
                      final paths = [for (final f in r) if (f.path != null && re.hasMatch(f.path!)) f.path!];
                      if (paths.isEmpty) return;
                      final n = await lib.import(paths);
                      if (context.mounted) toast(context, '已加入 $n 本');
                    },
                  ),
                IconButton(tooltip: '重新整理', icon: const Icon(LucideIcons.refreshCw), onPressed: lib.refresh),
              ]),
            ),
          ),
          if (cols.isNotEmpty) SliverToBoxAdapter(child: SectionHeader('合集（${cols.length}）')),
          if (cols.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: Ui.posterCard * 1.5 + (Ui.tv ? 86 : 62),
                child: ListView(scrollDirection: Axis.horizontal, padding: EdgeInsets.symmetric(horizontal: Ui.gutter), children: [
                  for (final c in cols)
                    Padding(
                      padding: EdgeInsets.only(right: Ui.gap),
                      child: ItemCard(
                        Item(src: 'local', id: 'col_${c.id}', title: c.name, cover: _colCover(c), sub: '${c.files.length} 本', type: 'comic', poster: true),
                        onTap: () => push(context, ReaderPage.collection(c)),
                        onLongPress: () => _collectionMenu(c),
                      ),
                    ),
                ]),
              ),
            ),
          SliverToBoxAdapter(child: SectionHeader('漫畫檔（${books.length}）')),
          if (books.isEmpty && !lib.loading)
            const SliverToBoxAdapter(child: EmptyView('書櫃是空的。下載的漫畫會放在這裡', icon: LucideIcons.library))
          else
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: Ui.posterCard + 12,
                  mainAxisSpacing: Ui.gap,
                  crossAxisSpacing: Ui.gap,
                  childAspectRatio: Ui.posterCard / (Ui.posterCard * 1.5 + (Ui.tv ? 80 : 58)),
                ),
                delegate: SliverChildBuilderDelegate(
                  (c, i) {
                    final b = books[i];
                    final h = Store.instance.historyOf(b.item.key);
                    return ItemCard(b.item,
                        width: double.infinity,
                        progress: h?.progress ?? 0,
                        onTap: () => push(context, ReaderPage.book(b)),
                        onLongPress: () => _bookMenu(b));
                  },
                  childCount: books.length,
                ),
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: Ui.gutter * 2)),
        ]);
      });

  String _colCover(Collection c) {
    final name = c.cover.isNotEmpty ? c.cover : (c.files.isEmpty ? '' : c.files.first);
    final b = lib.books.where((b) => b.name == name).firstOrNull;
    return b == null ? '' : 'cbz:${b.path}#0';
  }

  Future<void> _bookMenu(Book b) async {
    final cols = lib.collections;
    final pick = await pickOption(context, b.title, [
      ('read', '閱讀'),
      ('col', '加入合集'),
      if (!Ui.tv) ('share', '分享檔案'),
      ('delete', '刪除檔案'),
    ], null);
    if (!mounted) return;
    switch (pick) {
      case 'read':
        push(context, ReaderPage.book(b));
      case 'share':
        Native.shareFile(b.path, 'application/vnd.comicbook+zip');
      case 'delete':
        if (await confirm(context, '刪除漫畫檔', '刪除「${b.title}」？檔案會從手機刪除，無法復原。', ok: '刪除', danger: true)) await lib.delete(b);
      case 'col':
        final target = await pickOption(context, '加入哪個合集', [('new', '＋ 新的合集'), for (final c in cols) (c.id, c.name)], null);
        if (target == null || !mounted) return;
        if (target == 'new') {
          final name = await askText(context, '合集名稱', initial: b.title);
          if (name != null && name.trim().isNotEmpty) lib.createCollection(name.trim(), [b.name]);
        } else {
          final c = cols.firstWhere((c) => c.id == target);
          c.files.add(b.name);
          lib.updateCollection(c);
        }
    }
  }

  Future<void> _collectionMenu(Collection c) async {
    final pick = await pickOption(context, c.name, [
      ('read', '閱讀'),
      ('rename', '改名'),
      for (final (i, f) in c.files.indexed) ('out_$i', '移出：${lib.books.where((b) => b.name == f).firstOrNull?.title ?? f}'),
      ('dissolve', '解散合集（檔案不會刪）'),
    ], null);
    if (pick == null || !mounted) return;
    if (pick == 'read') {
      push(context, ReaderPage.collection(c));
    } else if (pick == 'rename') {
      final name = await askText(context, '合集名稱', initial: c.name);
      if (name != null && name.trim().isNotEmpty) lib.updateCollection(c..name = name.trim());
    } else if (pick == 'dissolve') {
      lib.deleteCollection(c.id);
    } else if (pick.startsWith('out_')) {
      c.files.removeAt(int.parse(pick.substring(4)));
      lib.updateCollection(c);
    }
  }
}

bool fileExists(String p) => File(p).existsSync();
