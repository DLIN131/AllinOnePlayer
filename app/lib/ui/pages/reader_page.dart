import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/comic/descramble.dart';
import '../../core/comic/library.dart';
import '../../core/model.dart';
import '../../core/native.dart';
import '../../core/registry.dart';
import '../../core/store.dart';
import '../theme.dart';
import '../widgets.dart';

/// 一本的目錄項（合集用）
class _Toc {
  final String title;
  final int start;
  final int count;
  final Item item;
  const _Toc(this.title, this.start, this.count, this.item);
}

/// 漫畫閱讀：直向捲動（手機預設）或左右翻頁（電視預設，遙控器左右鍵翻頁）
class ReaderPage extends StatefulWidget {
  final Detail? detail;
  final String? chapterId;
  final int startPage;
  final Book? book;
  final Collection? col;

  const ReaderPage.online(Detail d, {super.key, this.chapterId, this.startPage = 0})
      : detail = d,
        book = null,
        col = null;
  const ReaderPage.book(Book b, {super.key})
      : book = b,
        detail = null,
        chapterId = null,
        startPage = -1,
        col = null;
  const ReaderPage.collection(Collection c, {super.key})
      : col = c,
        detail = null,
        book = null,
        chapterId = null,
        startPage = -1;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  List<ReaderPage0> pages = [];
  List<_Toc> toc = [];
  Object? error;
  bool loading = true;
  String? chapterId;
  int current = 0;
  int start = 0;
  bool showBar = false;
  late bool paged = Store.instance.setting<String>('readerMode', Ui.tv ? 'paged' : 'vertical') == 'paged';
  late bool rtl = Store.instance.setting<bool>('rtl', false);
  final heights = <int, double>{};
  final scroll = ScrollController();
  PageController? pager;
  final focus = FocusNode();
  Timer? _saveTimer;

  Map<String, String> get headers => widget.detail == null ? const {} : src(widget.detail!.item.src).imageHeaders;

  @override
  void initState() {
    super.initState();
    chapterId = widget.chapterId;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    scroll.addListener(_onScroll);
    _load(widget.startPage);
  }

  @override
  void dispose() {
    _save();
    _saveTimer?.cancel();
    ReaderPage0.clearAll();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    scroll.dispose();
    pager?.dispose();
    focus.dispose();
    super.dispose();
  }

  Item get item {
    if (widget.detail != null) return widget.detail!.item;
    if (widget.col != null) return Item(src: 'local', id: 'col_${widget.col!.id}', title: widget.col!.name, cover: toc.isEmpty ? '' : toc.first.item.cover, type: 'comic', poster: true);
    return widget.book!.item;
  }

  Future<void> _load(int startPage) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final h = Store.instance.historyOf(item.key);
      if (widget.detail != null) {
        final s = src(widget.detail!.item.src);
        final list = await s.read(widget.detail!, chapterId);
        pages = [for (final p in list) ReaderPage0(p)];
      } else if (widget.book != null) {
        final b = widget.book!;
        pages = [for (var i = 0; i < b.pages; i++) ReaderPage0(ComicPage('cbz:${b.path}#$i'))];
      } else {
        final books = Library.instance.booksOf(widget.col!);
        pages = [];
        toc = [];
        for (final b in books) {
          toc.add(_Toc(b.title, pages.length, b.pages, b.item));
          for (var i = 0; i < b.pages; i++) {
            pages.add(ReaderPage0(ComicPage('cbz:${b.path}#$i')));
          }
        }
      }
      if (pages.isEmpty) throw NetError('沒有圖片');
      // 本機書：從上次的頁數接著讀
      if (startPage < 0) startPage = (h != null && h.total == pages.length) ? h.page : 0;
      start = startPage.clamp(0, pages.length - 1);
      current = start;
      heights.clear();
      pager?.dispose();
      pager = PageController(initialPage: start);
      if (scroll.hasClients) scroll.jumpTo(0);
      setState(() => loading = false);
      _save();
    } catch (e) {
      setState(() {
        loading = false;
        error = e;
      });
    }
  }

  // ---------- 進度 ----------

  void _setCurrent(int i) {
    if (i == current) return;
    setState(() => current = i);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _save);
  }

  void _save() {
    if (pages.isEmpty) return;
    final d = widget.detail;
    final ch = d?.chapters.where((c) => c.id == chapterId).firstOrNull;
    Store.instance.addHistory(HistoryEntry(item, DateTime.now().millisecondsSinceEpoch,
        chapterId: chapterId ?? '', chapterTitle: ch?.title ?? '', page: current, total: pages.length));
  }

  /// 直向模式：以「目前頁」的上緣為 0（center），往上是前面的頁
  void _onScroll() {
    if (paged || pages.isEmpty) return;
    final w = MediaQuery.of(context).size.width;
    double h(int i) => heights[i] ?? w * 1.45;
    final px = scroll.offset + 40;
    var i = start;
    if (px >= 0) {
      var acc = 0.0;
      while (i < pages.length - 1 && acc + h(i) <= px) {
        acc += h(i);
        i++;
      }
    } else {
      var acc = 0.0;
      while (i > 0 && acc > px) {
        i--;
        acc -= h(i);
      }
    }
    _setCurrent(i);
  }

  void _onSize(int i, double ratio) {
    final w = MediaQuery.of(context).size.width;
    final nh = w / ratio;
    if (heights[i] != nh) heights[i] = nh;
  }

  // ---------- 章節 ----------

  int get chapterIndex => widget.detail?.chapters.indexWhere((c) => c.id == chapterId) ?? -1;

  void _openChapter(int i) {
    final chs = widget.detail!.chapters;
    if (i < 0 || i >= chs.length) return;
    chapterId = chs[i].id;
    _load(0);
  }

  void _goto(int i) {
    i = i.clamp(0, pages.length - 1);
    if (paged) {
      pager?.jumpToPage(i);
    } else {
      setState(() {
        start = i;
        heights.clear();
      });
      scroll.jumpTo(0);
    }
    _setCurrent(i);
  }

  // ---------- 遙控器 / 鍵盤 ----------

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.contextMenu) {
      setState(() => showBar = !showBar);
      return KeyEventResult.handled;
    }
    if (showBar) return KeyEventResult.ignored;
    final fwd = rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
    final back = rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
    if (paged) {
      if (k == fwd || k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.pageDown) {
        _next();
        return KeyEventResult.handled;
      }
      if (k == back || k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.pageUp) {
        _prev();
        return KeyEventResult.handled;
      }
    } else {
      final step = MediaQuery.of(context).size.height * 0.8;
      if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.pageDown || k == fwd) {
        scroll.animateTo(scroll.offset + step, duration: Ui.dur(context, 220), curve: Curves.easeOut);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.pageUp || k == back) {
        scroll.animateTo(scroll.offset - step, duration: Ui.dur(context, 220), curve: Curves.easeOut);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _next() {
    if (current >= pages.length - 1) {
      if (chapterIndex >= 0 && chapterIndex < widget.detail!.chapters.length - 1) _openChapter(chapterIndex + 1);
      return;
    }
    pager?.nextPage(duration: Ui.dur(context, 200), curve: Curves.easeOut);
  }

  void _prev() {
    if (current <= 0) return;
    pager?.previousPage(duration: Ui.dur(context, 200), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (loading) {
      body = const Loading();
    } else if (error != null) {
      body = ErrorView(error!, onRetry: () => _load(current));
    } else {
      body = paged ? _pagedView() : _verticalView();
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(children: [
          Positioned.fill(child: GestureDetector(onTap: () => setState(() => showBar = !showBar), child: body)),
          if (!loading && pages.isNotEmpty) Positioned(right: 10, bottom: 10, child: IgnorePointer(child: _counter())),
          if (showBar) _topBar(),
          if (showBar && pages.isNotEmpty) _bottomBar(),
        ]),
      ),
    );
  }

  Widget _counter() {
    var label = '${current + 1} / ${pages.length}';
    if (toc.isNotEmpty) {
      final t = toc.lastWhere((t) => t.start <= current, orElse: () => toc.first);
      label = '第 ${toc.indexOf(t) + 1} 本 ${current - t.start + 1} / ${t.count}（總 $label）';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(color: C.fg, fontSize: Ui.small - 1)),
    );
  }

  Widget _verticalView() {
    final centerKey = const ValueKey('center');
    Widget page(int i) => _PageImage(pages[i], index: i, headers: headers, onSize: _onSize, fit: BoxFit.fitWidth);
    final end = _endWidget();
    return CustomScrollView(
      controller: scroll,
      center: centerKey,
      // 前後各多留幾頁不拆掉，往回捲時不用重新載入
      cacheExtent: MediaQuery.of(context).size.height * 3,
      slivers: [
        SliverList(delegate: SliverChildBuilderDelegate((c, i) => page(start - 1 - i), childCount: start)),
        SliverList(key: centerKey, delegate: SliverChildBuilderDelegate((c, i) => page(start + i), childCount: pages.length - start)),
        SliverToBoxAdapter(child: end),
      ],
    );
  }

  Widget _endWidget() {
    final hasNext = chapterIndex >= 0 && chapterIndex < (widget.detail?.chapters.length ?? 0) - 1;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(children: [
        Text('已經是最後一頁', style: TextStyle(color: C.mutedFg, fontSize: Ui.body)),
        const SizedBox(height: 12),
        if (hasNext)
          FilledButton.icon(
            onPressed: () => _openChapter(chapterIndex + 1),
            icon: const Icon(LucideIcons.chevronRight),
            label: Text('下一話：${widget.detail!.chapters[chapterIndex + 1].title}'),
          )
        else
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('返回')),
      ]),
    );
  }

  Widget _pagedView() => PageView.builder(
        controller: pager,
        reverse: rtl,
        itemCount: pages.length + 1,
        onPageChanged: (i) => _setCurrent(i.clamp(0, pages.length - 1)),
        itemBuilder: (c, i) => i == pages.length
            ? Center(child: _endWidget())
            : InteractiveViewer(
                maxScale: 4,
                child: Center(child: _PageImage(pages[i], index: i, headers: headers, onSize: (_, __) {}, fit: BoxFit.contain)),
              ),
      );

  Widget _topBar() => Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Container(
          color: Colors.black.withValues(alpha: 0.85),
          padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
          child: Row(children: [
            IconButton(autofocus: true, tooltip: '返回', icon: const Icon(LucideIcons.arrowLeft), onPressed: () => Navigator.pop(context)),
            Expanded(
              child: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.body)),
            ),
            if (widget.detail != null && widget.detail!.chapters.isNotEmpty)
              IconButton(
                tooltip: '章節',
                icon: const Icon(LucideIcons.listOrdered),
                onPressed: () async {
                  final pick = await pickOption(context, '章節', [for (final c in widget.detail!.chapters) (c.id, c.title)], chapterId);
                  if (pick != null && pick != chapterId) _openChapter(widget.detail!.chapters.indexWhere((c) => c.id == pick));
                },
              ),
            if (toc.isNotEmpty)
              IconButton(
                tooltip: '目錄',
                icon: const Icon(LucideIcons.listOrdered),
                onPressed: () async {
                  final pick = await pickOption(context, '目錄', [for (final t in toc) ('${t.start}', t.title)], null);
                  if (pick != null) _goto(int.parse(pick));
                },
              ),
            IconButton(
              tooltip: paged ? '改成直向捲動' : '改成左右翻頁',
              icon: Icon(paged ? LucideIcons.galleryVertical : LucideIcons.galleryHorizontal),
              onPressed: () {
                final keep = current;
                setState(() {
                  paged = !paged;
                  start = keep;
                  heights.clear();
                  pager?.dispose();
                  pager = PageController(initialPage: keep);
                });
                Store.instance.setSetting('readerMode', paged ? 'paged' : 'vertical');
              },
            ),
            if (paged)
              IconButton(
                tooltip: rtl ? '改成從左往右翻' : '改成從右往左翻（日漫）',
                icon: Icon(rtl ? LucideIcons.arrowLeftRight : LucideIcons.arrowRightLeft),
                onPressed: () {
                  setState(() => rtl = !rtl);
                  Store.instance.setSetting('rtl', rtl);
                },
              ),
          ]),
        ),
      );

  Widget _bottomBar() => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          color: Colors.black.withValues(alpha: 0.85),
          padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + MediaQuery.of(context).padding.bottom),
          child: Row(children: [
            Text('${current + 1}', style: TextStyle(fontSize: Ui.small)),
            Expanded(
              child: Slider(
                value: current.toDouble(),
                max: (pages.length - 1).toDouble().clamp(1, double.infinity),
                onChanged: (v) => setState(() => current = v.round()),
                onChangeEnd: (v) => _goto(v.round()),
              ),
            ),
            Text('${pages.length}', style: TextStyle(fontSize: Ui.small)),
          ]),
        ),
      );
}

/// 一頁（可能要先解析網址、可能要重組切條）
class ReaderPage0 {
  final ComicPage p;
  String? resolved;

  /// 圖片真正的寬高比（載過一次就記住）：頁面重建時佔位高度就對了，往回捲不會因為高度變來變去而跳動
  double? ratio;

  /// 拼回去的圖（切條打亂的頁才有）：重組很花時間，最近看過的留著，往回捲直接顯示
  ui.Image? image;

  ReaderPage0(this.p);

  static final _recent = <ReaderPage0>[];
  static const _keep = 16;

  void remember(ui.Image img) {
    image?.dispose();
    image = img;
    _recent
      ..remove(this)
      ..add(this);
    while (_recent.length > _keep) {
      final old = _recent.removeAt(0);
      old.image?.dispose();
      old.image = null;
    }
  }

  /// 離開閱讀器時把留著的圖都放掉
  static void clearAll() {
    for (final p in _recent) {
      p.image?.dispose();
      p.image = null;
    }
    _recent.clear();
  }
}

class _PageImage extends StatefulWidget {
  final ReaderPage0 page;
  final int index;
  final Map<String, String> headers;
  final void Function(int, double) onSize;
  final BoxFit fit;
  const _PageImage(this.page, {required this.index, required this.headers, required this.onSize, required this.fit});
  @override
  State<_PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<_PageImage> {
  ui.Image? _img;
  Object? _error;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  int _tries = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _img?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    // 最近看過、已經拼好的圖：直接用（自己拿一份 clone，快取那份由 ReaderPage0 管）
    final cached = widget.page.image;
    if (cached != null) {
      _img = cached.clone();
      return;
    }
    if (mounted) setState(() => _error = null);
    try {
      final p = widget.page.p;
      ImageProvider provider;
      if (p.url.startsWith('cbz:')) {
        final i = p.url.lastIndexOf('#');
        provider = MemoryImage(Library.instance.page(p.url.substring(4, i), int.parse(p.url.substring(i + 1))));
      } else {
        var url = p.url;
        if (p.resolve != null) {
          url = widget.page.resolved ??= await p.resolve!(_tries > 0);
        }
        provider = CachedNetworkImageProvider(url, headers: {'User-Agent': Native.info.userAgent, ...widget.headers});
      }
      if (!mounted) return;
      final stream = provider.resolve(createLocalImageConfiguration(context));
      _listener = ImageStreamListener((info, _) async {
        final src = info.image;
        widget.page.ratio = src.width / src.height;
        widget.onSize(widget.index, src.width / src.height);
        ui.Image out;
        if (p.segs > 0) {
          final whole = await descrambleImage(src, p.segs);
          widget.page.remember(whole);
          out = whole.clone();
        } else {
          out = src.clone();
        }
        info.dispose();
        if (!mounted) {
          out.dispose();
          return;
        }
        setState(() {
          _img?.dispose();
          _img = out;
        });
      }, onError: (e, _) => _fail(e));
      _stream = stream..addListener(_listener!);
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    // eh：換一台圖片伺服器再試一次
    if (widget.page.p.resolve != null && _tries == 0) {
      _tries++;
      widget.page.resolved = null;
      _start();
      return;
    }
    setState(() => _error = e);
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final p = widget.page.p;
    if (_img != null) {
      return RawImage(image: _img, fit: widget.fit, width: widget.fit == BoxFit.fitWidth ? w : null, filterQuality: FilterQuality.medium);
    }
    final ratio = widget.page.ratio ?? ((p.width > 0 && p.height > 0) ? p.width / p.height : 1 / 1.45);
    return SizedBox(
      width: w,
      height: widget.fit == BoxFit.fitWidth ? w / ratio : null,
      child: Center(
        child: _error != null
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                Text('第 ${widget.index + 1} 頁載入失敗', style: TextStyle(color: C.mutedFg, fontSize: Ui.small)),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () {
                  _tries = 0;
                  widget.page.resolved = null;
                  _start();
                }, child: const Text('重試')),
              ])
            : Text('${widget.index + 1}', style: TextStyle(color: C.border, fontSize: Ui.title)),
      ),
    );
  }
}
