import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/auth.dart';
import '../../core/comic/comic_downloads.dart';
import '../../core/model.dart';
import '../../core/native.dart';
import '../../core/playback.dart';
import '../../core/registry.dart';
import '../../core/site_fav.dart';
import '../../core/source.dart';
import '../../core/sources/comic_common.dart';
import '../../core/sources/va.dart';
import '../../core/store.dart';
import '../../core/util.dart';
import '../nav.dart';
import '../theme.dart';
import '../widgets.dart';
import 'list_page.dart';
import 'reader_page.dart';
import 'search_page.dart';

/// 作品頁（影片、劇集、漫畫共用）
class DetailPage extends StatefulWidget {
  final Item item;
  const DetailPage(this.item, {super.key});
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final Source s = src(widget.item.src);
  Detail? d;
  Object? error;
  final _once = Once();

  /// va：網站帳號收藏狀態（null = 沒登入或不知道）
  bool? siteSaved;
  List<(String, String)>? actresses;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      error = null;
    });
    try {
      final r = await s.detail(widget.item);
      if (!mounted) return;
      setState(() => d = r);
      _afterLoad(r);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  void _afterLoad(Detail r) {
    if (s.key == 'va') {
      // 跟網站一樣：打開影片頁就通知網站（記觀看紀錄），順便拿有沒有收藏
      final id = r.extra['itemId'] as String?;
      if (id != null && Auth.accountName('va').isNotEmpty) {
        va.itemView(id).then((v) => mounted ? setState(() => siteSaved = v) : null).catchError((_) {});
      }
      VaLookup.find(r.item.id).then((v) => mounted ? setState(() => actresses = v) : null).catchError((_) {
        if (mounted) setState(() => actresses = const []);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = d == null
        ? (error != null ? ErrorView(error!, onRetry: _load) : const Loading())
        : RefreshIndicator(onRefresh: _load, child: _content(d!));
    return Scaffold(
      appBar: AppBar(
        title: Text(d?.title ?? widget.item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.body + 1)),
        actions: [
          if (d != null && d!.url.isNotEmpty)
            IconButton(
              tooltip: '在網頁開啟',
              icon: const Icon(LucideIcons.globe),
              onPressed: () => Native.openWeb(site: s.key, url: d!.url, mode: 'browse', title: d!.title),
            ),
        ],
      ),
      body: body,
    );
  }

  Widget _content(Detail d) {
    final wide = MediaQuery.of(context).size.width > 760;
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(Ui.radius),
      child: AspectRatio(aspectRatio: d.item.poster || s.isComic ? 2 / 3 : 16 / 9, child: Cover(d.cover.isNotEmpty ? d.cover : d.item.cover, site: s.key)),
    );
    // 標題很長（漫畫常見）時字小一點
    final long = d.title.length > 40;
    final titleBlock = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        SourceBadge(s.key),
        if (d.lang.isNotEmpty) Text(Lang.names[d.lang] ?? '', style: TextStyle(color: C.mutedFg, fontSize: Ui.small)),
        if (d.subtitle.isNotEmpty && !s.isComic) Text(d.subtitle, style: TextStyle(color: C.mutedFg, fontSize: Ui.small)),
      ]),
      const SizedBox(height: 8),
      SelectableText(d.title, style: TextStyle(fontSize: long ? Ui.body + 1 : Ui.title, fontWeight: FontWeight.w700, height: 1.4)),
      if (d.subtitle.isNotEmpty && s.isComic) Padding(padding: const EdgeInsets.only(top: 4), child: Text(d.subtitle, style: TextStyle(color: C.mutedFg, fontSize: Ui.small))),
    ]);
    final actions = Padding(padding: const EdgeInsets.only(top: 14), child: _actions(d));
    final poster = s.isComic || d.item.poster;
    return ListView(
      padding: EdgeInsets.only(bottom: Ui.tv ? 48 : 32),
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 0),
          child: wide
              // 寬螢幕（平板、電視）：封面在左，標題和按鈕在右
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: poster ? (Ui.tv ? 190 : 200) : (Ui.tv ? 380 : 360), child: cover),
                  SizedBox(width: Ui.gap + 4),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [titleBlock, actions])),
                ])
              : poster
                  // 手機直式封面：封面和標題並排，按鈕佔整行
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 120, child: cover),
                        const SizedBox(width: 14),
                        Expanded(child: titleBlock),
                      ]),
                      actions,
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [cover, const SizedBox(height: 14), titleBlock, actions]),
        ),
        ..._info(d),
        if (d.description.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(Ui.gutter, 12, Ui.gutter, 0),
            child: Text(d.description, style: TextStyle(color: C.mutedFg, fontSize: Ui.body - 1, height: 1.6)),
          ),
        if (d.tags.isNotEmpty) ...[
          SectionHeader('標籤'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
            child: Wrap(spacing: 8, runSpacing: 8, children: [for (final t in d.tags) _chip(t.title, () => _openTag(t))]),
          ),
        ],
        if (d.chapters.isNotEmpty) ..._chapters(d),
        if (d.episodes.isNotEmpty)
          ShelfRow(
            title: '${d.episodesTitle}（${d.episodes.length}）',
            items: d.episodes,
            progressOf: (e) => _progress(e.key),
            onTap: (e) => s.key == 'vc' ? _play(d, e) : openItem(context, e),
          ),
        if (d.related.isNotEmpty) ShelfRow(title: s.isComic ? '相關作品' : '相關影片', items: d.related, onTap: (e) => openItem(context, e)),
      ],
    );
  }

  double _progress(String key) {
    final h = Store.instance.historyOf(key);
    final pos = Store.instance.position(key);
    if (h != null && h.duration > 0) return (pos > 0 ? pos : h.position) / h.duration;
    return 0;
  }

  Widget _chip(String label, VoidCallback onTap) => Tap(
        radius: 18,
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: Ui.tv ? 16 : 12, vertical: Ui.tv ? 10 : 7),
          decoration: BoxDecoration(color: C.muted, borderRadius: BorderRadius.circular(18), border: Border.all(color: C.border)),
          child: Text(label, style: TextStyle(fontSize: Ui.small)),
        ),
      );

  void _openTag(Link t) {
    if (t.params['q'] != null) {
      push(context, ListPage(link: Link(t.src, t.title, {'q': t.params['q']!})));
    } else {
      openLink(context, t);
    }
  }

  List<Widget> _info(Detail d) {
    final rows = [...d.info];
    final out = <Widget>[];
    for (final r in rows) {
      out.add(Padding(
        padding: EdgeInsets.fromLTRB(Ui.gutter, 10, Ui.gutter, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: Ui.tv ? 120 : 76, child: Text(r.label, style: TextStyle(color: C.mutedFg, fontSize: Ui.small))),
          Expanded(
            child: r.links.isEmpty
                ? SelectableText(r.text, style: TextStyle(fontSize: Ui.small, height: 1.4))
                : Wrap(spacing: 8, runSpacing: 8, children: [for (final l in r.links) _chip(l.title, () => openLink(context, l))]),
          ),
        ]),
      ));
    }
    if (s.key == 'va') {
      out.add(Padding(
        padding: EdgeInsets.fromLTRB(Ui.gutter, 10, Ui.gutter, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: Ui.tv ? 120 : 76, child: Text('女優（番號查詢）', style: TextStyle(color: C.mutedFg, fontSize: Ui.small - 1))),
          Expanded(
            child: actresses == null
                ? Text('查詢中…', style: TextStyle(color: C.mutedFg, fontSize: Ui.small))
                : actresses!.isEmpty
                    ? Text('查不到', style: TextStyle(color: C.mutedFg, fontSize: Ui.small))
                    : Wrap(spacing: 8, runSpacing: 8, children: [
                        // 點名字＝在主站搜尋她的作品
                        for (final a in actresses!) _chip(a.$1, () => push(context, ListPage(link: Link('va', a.$1, {'q': a.$1})))),
                      ]),
          ),
        ]),
      ));
    }
    return out;
  }

  // ---------- 動作 ----------

  Widget _actions(Detail d) {
    final store = Store.instance;
    return Watch(store, (_) {
      final fav = store.isFavorite(d.item.key);
      final buttons = <Widget>[];
      if (s.isComic) {
        final h = store.historyOf(d.item.key);
        final resume = h != null && (h.page > 0 || h.chapterId.isNotEmpty);
        buttons.add(FilledButton.icon(
          autofocus: true,
          onPressed: () => _read(d, chapterId: resume ? h.chapterId : null, page: resume ? h.page : 0),
          icon: const Icon(LucideIcons.bookOpen),
          label: Text(resume ? '繼續閱讀（${h.chapterTitle.isNotEmpty ? '${h.chapterTitle} ' : ''}第 ${h.page + 1}${h.total > 0 ? ' / ${h.total}' : ''} 頁）' : '開始閱讀'),
        ));
        if (resume) buttons.add(OutlinedButton(onPressed: () => _read(d, chapterId: d.chapters.isNotEmpty ? d.chapters.first.id : null), child: const Text('從頭開始')));
      } else {
        final pos = store.position((d.item.type == 'series' ? (store.historyOf(d.item.key)?.episode ?? d.item) : d.item).key);
        final h = store.historyOf(d.item.key);
        final label = d.item.type == 'series'
            ? (h?.episode != null ? '繼續播放：${h!.episode!.title}' : '播放第一集')
            : (pos > 5000 ? '繼續播放（${fmtTime(pos / 1000)}）' : '播放');
        buttons.add(FilledButton.icon(
          autofocus: true,
          onPressed: () => _play(d, d.item.type == 'series' ? h?.episode : null),
          icon: const Icon(LucideIcons.play),
          label: Text(label),
        ));
      }
      buttons.add(OutlinedButton.icon(
        onPressed: () {
          store.setFavorite(d.item, !fav);
          toast(context, fav ? '已從收藏移除' : '已加入收藏');
        },
        icon: Icon(LucideIcons.heart, color: fav ? C.accent : null),
        label: Text(fav ? '已收藏' : '收藏'),
      ));
      // 網站收藏按鈕：va（登入後）和漫畫站；vb 的清單要在網站上管理
      if ((s.key == 'va' && Auth.accountName('va').isNotEmpty) || (s.isComic && s.hasAccount)) {
        buttons.add(OutlinedButton.icon(onPressed: () => _siteFav(d), icon: const Icon(LucideIcons.bookmark), label: Text(s.key == 'va' && siteSaved == true ? '已在網站收藏' : '網站收藏')));
      }
      if (!Ui.tv) buttons.add(OutlinedButton.icon(onPressed: () => _download(d), icon: const Icon(LucideIcons.download), label: const Text('下載')));
      if (s.isComic) {
        buttons.add(OutlinedButton.icon(
          onPressed: () => push(context, SearchPage(initial: Query.cleanTitle(d.title), comicsOnly: true)),
          icon: const Icon(LucideIcons.search),
          label: const Text('各站搜同一本'),
        ));
        for (final a in Query.parseAuthors(d.title).take(2)) {
          buttons.add(OutlinedButton.icon(onPressed: () => push(context, SearchPage(initial: a, comicsOnly: true)), icon: const Icon(LucideIcons.user), label: Text(a)));
        }
      }
      return Wrap(spacing: 10, runSpacing: 10, children: buttons);
    });
  }

  Future<void> _play(Detail d, [Item? episode]) => _once.run(() async {
        try {
          await Playback.play(d, episode: episode);
          if (mounted) setState(() {});
        } on NetError catch (e) {
          if (mounted) toast(context, e.message);
        } catch (e) {
          if (mounted) toast(context, '無法播放：$e');
        }
      });

  void _read(Detail d, {String? chapterId, int page = 0}) {
    if (d.chapters.isNotEmpty && chapterId == null) chapterId = d.chapters.first.id;
    push(context, ReaderPage.online(d, chapterId: chapterId, startPage: page)).then((_) => mounted ? setState(() {}) : null);
  }

  List<Widget> _chapters(Detail d) {
    final h = Store.instance.historyOf(d.item.key);
    return [
      SectionHeader('章節（${d.chapters.length}）'),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: Ui.gutter),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in d.chapters)
            Tap(
              radius: 8,
              onTap: () => _read(d, chapterId: c.id, page: h?.chapterId == c.id ? h!.page : 0),
              onLongPress: Ui.tv ? null : () => _downloadChapter(d, c),
              child: Container(
                constraints: BoxConstraints(minWidth: Ui.tv ? 140 : 88),
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: Ui.tv ? 12 : 9),
                decoration: BoxDecoration(
                  color: h?.chapterId == c.id ? C.accent.withValues(alpha: 0.2) : C.muted,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: h?.chapterId == c.id ? C.accent : C.border),
                ),
                child: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.small)),
              ),
            ),
        ]),
      ),
    ];
  }

  Future<void> _siteFav(Detail d) async {
    try {
      switch (s.key) {
        case 'va':
          final id = d.extra['itemId'] as String?;
          if (id == null) throw NetError('找不到這部影片在網站的編號');
          final on = siteSaved != true;
          await va.setSaved(id, on);
          setState(() => siteSaved = on);
          if (mounted) toast(context, on ? '已加到網站收藏' : '已從網站收藏移除');
        case 'nh':
          final on = !(await nh.isFavorite(d.item.id));
          await nh.setFavorite(d.item.id, on);
          if (mounted) toast(context, on ? '已加到網站收藏' : '已從網站收藏移除');
        case 'jm':
          final msg = await jm.addFavorite(d.item.id);
          if (mounted) toast(context, msg);
        default:
          final form = await SiteFav.form(d);
          String? choice;
          if (form.choices.length > 1 && mounted) {
            choice = await pickOption(context, '加到哪個收藏夾', form.choices, form.selected);
            if (choice == null) return;
          }
          final msg = await SiteFav.submit(d, form, choice);
          if (mounted) toast(context, msg);
      }
    } on LoginError catch (e) {
      if (!mounted) return;
      if (s.key == 'va') {
        toast(context, '請先到「我的」登入帳號');
      } else if (await confirm(context, '需要登入', e.message, ok: '登入')) {
        await Auth.loginWeb(s.key);
      }
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, '$e');
    }
  }

  // ---------- 下載 ----------

  Future<void> _download(Detail d) async {
    if (s.isComic) {
      if (d.chapters.length > 1) {
        final pick = await pickOption(context, '下載哪一話', [('all', '全部 ${d.chapters.length} 話（各存一個檔）'), for (final c in d.chapters) (c.id, c.title)], null);
        if (pick == null) return;
        for (final c in d.chapters) {
          if (pick == 'all' || pick == c.id) ComicDownloads.instance.add(d.item, chapterId: c.id, chapterTitle: c.title);
        }
      } else {
        ComicDownloads.instance.add(d.item);
      }
      if (mounted) toast(context, '已加入下載（到「收藏 › 下載」看進度）');
      return;
    }
    Item? ep;
    if (d.item.type == 'series') {
      if (d.episodes.isEmpty) return;
      final pick = await pickOption(context, '下載哪一集', [for (final e in d.episodes) (e.id, e.title)], null);
      if (pick == null) return;
      ep = d.episodes.firstWhere((e) => e.id == pick);
    }
    try {
      final st = await s.stream(d, episode: ep);
      String url = st.url, quality = '';
      if (st.kind == 'mp4') {
        if (st.qualities.length > 1 && mounted) {
          final q = await pickOption(context, '選擇畫質', st.qualities.map((e) => (e.$2, e.$1)).toList(), st.qualities.first.$2);
          if (q == null) return;
          url = q;
        }
        quality = st.qualities.firstWhere((e) => e.$2 == url, orElse: () => ('', url)).$1;
      } else {
        final vs = await Native.variants(st.url, st.conn);
        if (vs.length > 1 && mounted) {
          final q = await pickOption(context, '選擇畫質', [
            for (final v in vs) ('${v['url']}', '${v['height']}p${(v['bandwidth'] as num) > 0 ? '（約 ${fmtSize((v['bandwidth'] as num) / 8 * 3600)}／小時）' : ''}'),
          ], '${vs.first['url']}');
          if (q == null) return;
          url = q;
          quality = '${vs.firstWhere((v) => v['url'] == q)['height']}p';
        } else if (vs.isNotEmpty) {
          url = '${vs.first['url']}';
          quality = '${vs.first['height']}p';
        }
      }
      await VideoDownloads.instance.start(d, st, episode: ep, url: url, quality: quality);
      if (mounted) toast(context, '已加入下載（到「收藏 › 下載」看進度）');
    } on NetError catch (e) {
      if (mounted) toast(context, e.message);
    } catch (e) {
      if (mounted) toast(context, '無法下載：$e');
    }
  }

  void _downloadChapter(Detail d, Chapter c) {
    ComicDownloads.instance.add(d.item, chapterId: c.id, chapterTitle: c.title);
    toast(context, '已加入下載：${c.title}');
  }
}
