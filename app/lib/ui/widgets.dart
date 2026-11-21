import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/auth.dart';
import '../core/comic/library.dart';
import '../core/model.dart';
import '../core/native.dart';
import '../core/registry.dart';
import '../core/sites.dart';
import '../core/sources/comic_common.dart';
import 'preview.dart';
import 'theme.dart';

void toast(BuildContext context, String msg) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
}

/// 可以點、也可以用遙控器選到的區塊：選到時有白色外框和輕微放大（不改變排版大小）
class Tap extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double radius;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;
  final ValueChanged<bool>? onFocus;
  const Tap({super.key, required this.child, this.onTap, this.onLongPress, this.radius = 10, this.autofocus = false, this.focusNode, this.semanticLabel, this.onFocus});

  @override
  State<Tap> createState() => _TapState();
}

class _TapState extends State<Tap> {
  bool _focused = false;

  /// 電視：按住 OK 鍵（遙控器會一直送重複的按鍵）＝長按；放開時沒到長按才算點一下
  bool _okDown = false;
  bool _longFired = false;

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (widget.onLongPress == null) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k != LogicalKeyboardKey.select && k != LogicalKeyboardKey.enter && k != LogicalKeyboardKey.numpadEnter && k != LogicalKeyboardKey.gameButtonA) {
      return KeyEventResult.ignored;
    }
    if (e is KeyDownEvent) {
      _okDown = true;
      _longFired = false;
    } else if (e is KeyRepeatEvent) {
      if (_okDown && !_longFired) {
        _longFired = true;
        widget.onLongPress!();
      }
    } else if (e is KeyUpEvent) {
      final tap = _okDown && !_longFired;
      _okDown = false;
      if (tap) widget.onTap?.call();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.radius);
    final body = _build(r);
    if (!Ui.tv || widget.onLongPress == null) return body;
    return Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: body);
  }

  Widget _build(BorderRadius r) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: AnimatedScale(
        scale: _focused && Ui.tv ? 1.05 : 1,
        duration: Ui.dur(context, 140),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          borderRadius: r,
          child: InkWell(
            borderRadius: r,
            autofocus: widget.autofocus,
            focusNode: widget.focusNode,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            focusColor: Colors.white.withValues(alpha: 0.06),
            onFocusChange: (f) {
              setState(() => _focused = f);
              widget.onFocus?.call(f);
            },
            child: Container(
              foregroundDecoration: _focused ? BoxDecoration(borderRadius: r, border: Border.all(color: C.ring, width: Ui.tv ? 3 : 2)) : null,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面：網址（帶各站的 Referer）、本機漫畫檔（cbz:路徑#頁）或本機檔案
class Cover extends StatelessWidget {
  final String url;
  final String? site;
  final BoxFit fit;
  final double? cacheWidth;
  const Cover(this.url, {super.key, this.site, this.fit = BoxFit.cover, this.cacheWidth});

  /// 截圖測試：不用快取套件（測試環境沒有資料庫），由測試提供抓圖的方法
  static Future<Uint8List> Function(String url, Map<String, String> headers)? testLoader;

  @override
  Widget build(BuildContext context) {
    final ph = Container(color: C.muted, alignment: Alignment.center, child: Icon(LucideIcons.image, color: C.border, size: Ui.icon));
    if (url.isEmpty) return ph;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cw = cacheWidth != null ? (cacheWidth! * dpr).round() : null;
    if (url.startsWith('cbz:')) {
      final i = url.lastIndexOf('#');
      final bytes = Library.instance.cover(url.substring(4, i));
      return bytes == null ? ph : Image.memory(bytes, fit: fit, cacheWidth: cw, gaplessPlayback: true, errorBuilder: (_, __, ___) => ph);
    }
    if (url.startsWith('/')) return Image.file(File(url), fit: fit, cacheWidth: cw, errorBuilder: (_, __, ___) => ph);
    final key = site ?? Sites.siteForUrl(url);
    final tl = testLoader;
    if (tl != null) {
      return FutureBuilder<Uint8List>(
        future: tl(url, {if (key != null && sources[key] != null) ...src(key).imageHeaders}),
        builder: (_, s) => s.hasData ? Image.memory(s.data!, fit: fit, errorBuilder: (_, __, ___) => ph) : ph,
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: {'User-Agent': Native.info.userAgent, if (key != null && sources[key] != null) ...src(key).imageHeaders},
      fit: fit,
      memCacheWidth: cw,
      fadeInDuration: Ui.dur(context, 150),
      placeholder: (_, __) => Container(color: C.muted),
      errorWidget: (_, __, ___) => ph,
    );
  }
}

/// 來源小標籤
class SourceBadge extends StatelessWidget {
  final String site;
  const SourceBadge(this.site, {super.key});
  @override
  Widget build(BuildContext context) {
    final d = Sites.byKey[site];
    final color = Color(d?.color ?? 0xFF94A3B8);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Ui.tv ? 8 : 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.8))),
      child: Text(site == 'local' ? '本機' : Sites.label(site), style: TextStyle(color: C.fg, fontSize: Ui.tv ? 14 : 10, fontWeight: FontWeight.w600)),
    );
  }
}

/// 列表裡的一張卡片
class ItemCard extends StatelessWidget {
  final Item item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double? width;
  final bool showSource;
  final double progress;
  final bool autofocus;

  /// 格狀列表裡統一比例（null = 依項目自己的封面方向）
  final bool? poster;

  /// 影片長按是預覽；呼叫端原本的長按功能（onLongPress）變成預覽框裡的按鈕，這是按鈕上的字
  final String? longPressLabel;
  const ItemCard(this.item,
      {super.key, required this.onTap, this.onLongPress, this.width, this.showSource = false, this.progress = 0, this.autofocus = false, this.poster, this.longPressLabel});

  @override
  Widget build(BuildContext context) {
    final isPoster = poster ?? item.poster;
    final w = width ?? (isPoster ? Ui.posterCard : Ui.wideCard);
    final ratio = isPoster ? 2 / 3 : 16 / 9;
    return SizedBox(
      width: w,
      child: Tap(
        onTap: onTap,
        onLongPress: canPreview(item)
            ? () => showPreview(context, item, onOpen: onTap, action: onLongPress == null ? null : (longPressLabel ?? '更多', onLongPress!))
            : onLongPress,
        autofocus: autofocus,
        semanticLabel: item.title,
        radius: Ui.radius,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(Ui.radius),
            child: AspectRatio(
              aspectRatio: ratio,
              child: Stack(fit: StackFit.expand, children: [
                // 格狀列表裡寬度是 infinity（由格子決定），解碼尺寸用一般卡片寬度的 1.3 倍
                Cover(item.cover, site: item.src, cacheWidth: w.isFinite ? w : (isPoster ? Ui.posterCard : Ui.wideCard) * 1.3),
                if (showSource) Positioned(left: 6, top: 6, child: SourceBadge(item.src)),
                if (item.lang.isNotEmpty)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(5)),
                      child: Text(Lang.short[item.lang] ?? '', style: TextStyle(fontSize: Ui.tv ? 13 : 10, color: C.fg)),
                    ),
                  ),
                if (item.sub.isNotEmpty && !isPoster)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(5)),
                      child: Text(item.sub, style: TextStyle(fontSize: Ui.tv ? 14 : 11, color: C.fg)),
                    ),
                  ),
                if (progress > 0)
                  Positioned(left: 0, right: 0, bottom: 0, child: LinearProgressIndicator(value: progress.clamp(0, 1), minHeight: 3, backgroundColor: Colors.black54)),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
            child: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.small, height: 1.35, color: C.fg)),
          ),
          if (item.sub.isNotEmpty && isPoster)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(item.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.small - 2, color: C.mutedFg)),
            ),
        ]),
      ),
    );
  }
}

/// 標題列（左邊標題，右邊「更多」）
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onMore;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.onMore, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(Ui.gutter, Ui.tv ? 20 : 14, Ui.gutter - 8, 6),
        child: Row(children: [
          Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.tv ? 24 : 17, fontWeight: FontWeight.w700))),
          if (trailing != null) trailing!,
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('更多', style: TextStyle(color: C.mutedFg, fontSize: Ui.small)),
                Icon(LucideIcons.chevronRight, size: Ui.icon - 4, color: C.mutedFg),
              ]),
            ),
        ]),
      );
}

/// 一列橫向卷動的卡片
class ShelfRow extends StatelessWidget {
  final String title;
  final List<Item> items;
  final void Function(Item) onTap;
  final VoidCallback? onMore;
  final bool showSource;
  final double Function(Item)? progressOf;
  final void Function(Item)? onLongPress;
  const ShelfRow({super.key, required this.title, required this.items, required this.onTap, this.onMore, this.showSource = false, this.progressOf, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    // 每張卡用自己的寬度（直式／橫式），列高取最高的那種，混在一起（例如繼續觀看＋閱讀）也不會溢出
    final hasPoster = items.any((e) => e.poster);
    final hasWide = items.any((e) => !e.poster);
    final ph = hasPoster ? Ui.posterCard * 3 / 2 + (Ui.tv ? 92 : 68) : 0.0;
    final wh = hasWide ? Ui.wideCard * 9 / 16 + (Ui.tv ? 86 : 62) : 0.0;
    final h = ph > wh ? ph : wh;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title, onMore: onMore),
      SizedBox(
        height: h,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: Ui.gutter, vertical: Ui.tv ? 8 : 0),
          clipBehavior: Clip.none,
          itemCount: items.length,
          separatorBuilder: (_, __) => SizedBox(width: Ui.gap),
          itemBuilder: (_, i) => ItemCard(items[i],
              showSource: showSource,
              progress: progressOf?.call(items[i]) ?? 0,
              onTap: () => onTap(items[i]),
              onLongPress: onLongPress == null ? null : () => onLongPress!(items[i])),
        ),
      ),
    ]);
  }
}

/// 錯誤畫面：被網站驗證擋住時可以開驗證頁；登入過期時可以去登入
class ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  final bool compact;
  const ErrorView(this.error, {super.key, required this.onRetry, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final e = error;
    final msg = e is NetError ? e.message : '載入失敗：$e';
    final buttons = <Widget>[
      if (e is BlockedError)
        FilledButton.icon(
          onPressed: () async {
            await Native.openWeb(site: e.site, url: '${Sites.base(e.site)}/', mode: 'verify', title: '完成驗證後按「驗證完成」');
            onRetry();
          },
          icon: const Icon(LucideIcons.shieldCheck),
          label: const Text('開啟驗證頁'),
        ),
      if (e is LoginError && e.site != 'va')
        FilledButton.icon(
          onPressed: () async {
            await loginSite(context, e.site);
            onRetry();
          },
          icon: const Icon(LucideIcons.logIn),
          label: Text('登入 ${Sites.label(e.site)}'),
        ),
      OutlinedButton.icon(onPressed: onRetry, icon: const Icon(LucideIcons.refreshCw), label: const Text('重試')),
    ];
    return Center(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!compact) Icon(LucideIcons.circleAlert, size: Ui.tv ? 48 : 36, color: C.mutedFg),
          if (!compact) const SizedBox(height: 12),
          Text(msg, textAlign: TextAlign.center, style: TextStyle(color: C.mutedFg, fontSize: Ui.body, height: 1.5)),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: buttons),
        ]),
      ),
    );
  }
}

class Loading extends StatelessWidget {
  const Loading({super.key});
  @override
  Widget build(BuildContext context) => const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()));
}

class EmptyView extends StatelessWidget {
  final String text;
  final IconData icon;
  const EmptyView(this.text, {super.key, this.icon = LucideIcons.inbox});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: Ui.tv ? 48 : 36, color: C.border),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: C.mutedFg, fontSize: Ui.body)),
          ]),
        ),
      );
}

/// 一組篩選：顯示目前選的值，點了跳出選項（遙控器也能用）
class FilterBar extends StatelessWidget {
  final List<FilterSpec> filters;
  final Map<String, String> values;
  final void Function(String key, String value) onChanged;
  const FilterBar({super.key, required this.filters, required this.values, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (filters.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: Ui.tv ? 60 : 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: Ui.gutter, vertical: 4),
        children: [
          for (final f in filters) ...[
            _chip(context, f),
            SizedBox(width: Ui.tv ? 12 : 8),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, FilterSpec f) {
    final v = values[f.key] ?? f.defaultValue;
    final label = f.options.firstWhere((o) => o.$1 == v, orElse: () => f.options.first).$2;
    final changed = v != f.defaultValue;
    return Tap(
      radius: 20,
      onTap: () async {
        final picked = await pickOption(context, f.label, f.options, v);
        if (picked != null && picked != v) onChanged(f.key, picked);
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: Ui.tv ? 18 : 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: changed ? C.accent.withValues(alpha: 0.18) : C.muted,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: changed ? C.accent : C.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${f.label}：', style: TextStyle(color: C.mutedFg, fontSize: Ui.small)),
          Text(label, style: TextStyle(color: C.fg, fontSize: Ui.small, fontWeight: FontWeight.w600)),
          Icon(LucideIcons.chevronDown, size: Ui.small + 2, color: C.mutedFg),
        ]),
      ),
    );
  }
}

/// 選一個選項（手機是底部清單，電視是對話框）
Future<String?> pickOption(BuildContext context, String title, List<(String, String)> options, String? current) {
  Widget list(BuildContext c) => ListView(shrinkWrap: true, children: [
        for (final (i, o) in options.indexed)
          ListTile(
            autofocus: o.$1 == current || (current == null && i == 0),
            title: Text(o.$2, style: TextStyle(fontSize: Ui.body)),
            trailing: o.$1 == current ? const Icon(LucideIcons.check, color: C.accent) : null,
            onTap: () => Navigator.pop(c, o.$1),
          ),
      ]);
  if (Ui.tv) {
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 480, child: list(c)),
      ),
    );
  }
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (c) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
        Flexible(child: list(c)),
      ]),
    ),
  );
}

/// 開網站自己的登入頁；登入成功後（網站那邊登入會自己失效的站）問要不要讓 App 記住密碼
Future<AuthState> loginSite(BuildContext context, String site) async {
  final s = await Auth.loginWeb(site);
  if (s.canRemember && context.mounted) {
    final yes = await confirm(
      context,
      '記住密碼？',
      '${Sites.label(site)} 網站那邊的登入一陣子沒用就會失效。讓 App 記住密碼的話，失效時會在背景自動重新登入，不用再自己登。\n\n'
          '密碼用這台裝置的金鑰加密，只存在這台裝置；登出或在「我的」按「忘記密碼」就會刪掉。',
      ok: '記住',
    );
    await Native.credRemember(site, yes);
    return s.copyWith(remembered: yes, canRemember: false);
  }
  return s;
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = '確定', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body, style: TextStyle(color: C.mutedFg, fontSize: Ui.body, height: 1.5)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(
          autofocus: true,
          style: danger ? const ButtonStyle(backgroundColor: WidgetStatePropertyAll(C.danger)) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}

Future<String?> askText(BuildContext context, String title, {String initial = '', String hint = '', TextInputType? type}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctl, autofocus: true, keyboardType: type, decoration: InputDecoration(hintText: hint), onSubmitted: (v) => Navigator.pop(c, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('確定')),
      ],
    ),
  );
}

/// 分頁載入的格狀列表（捲到底自動載下一頁）
class PagedGrid extends StatefulWidget {
  final Future<PageResult> Function(int page) load;
  final void Function(Item) onTap;
  final void Function(Item)? onLongPress;
  final bool showSource;
  final List<Widget> header;
  final String emptyText;
  final bool Function(Item)? filter;
  const PagedGrid({super.key, required this.load, required this.onTap, this.onLongPress, this.showSource = false, this.header = const [], this.emptyText = '沒有內容', this.filter});

  @override
  State<PagedGrid> createState() => PagedGridState();
}

class PagedGridState extends State<PagedGrid> {
  final items = <Item>[];
  final _keys = <String>{};
  int _page = 0;
  bool _more = true;
  bool _loading = false;
  Object? _error;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _next();
  }

  void reload() {
    setState(() {
      _gen++;
      items.clear();
      _keys.clear();
      _page = 0;
      _more = true;
      _loading = false;
      _error = null;
    });
    _next();
  }

  Future<void> _next() async {
    if (_loading || !_more) return;
    final gen = _gen;
    setState(() {
      _loading = true;
      _error = null;
    });
    // 篩選後一頁可能沒東西，多抓幾頁
    var tries = 0;
    try {
      while (tries < 5) {
        tries++;
        final r = await widget.load(_page + 1);
        if (gen != _gen || !mounted) return;
        _page++;
        final got = r.items.where((e) => _keys.add(e.key) && (widget.filter?.call(e) ?? true)).toList();
        items.addAll(got);
        _more = r.hasMore && r.items.isNotEmpty;
        if (got.isNotEmpty || !_more) break;
      }
    } catch (e) {
      if (gen != _gen || !mounted) return;
      _error = e;
    }
    if (mounted && gen == _gen) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final poster = items.isNotEmpty && items.where((e) => e.poster).length > items.length / 2;
    final w = poster ? Ui.posterCard : Ui.wideCard;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < 600) _next();
        return false;
      },
      child: CustomScrollView(slivers: [
        ...widget.header.map((h) => SliverToBoxAdapter(child: h)),
        if (items.isEmpty && _error != null)
          SliverFillRemaining(hasScrollBody: false, child: ErrorView(_error!, onRetry: reload))
        else if (items.isEmpty && !_loading && !_more)
          SliverFillRemaining(hasScrollBody: false, child: EmptyView(widget.emptyText))
        else ...[
          SliverPadding(
            padding: EdgeInsets.fromLTRB(Ui.gutter, 8, Ui.gutter, 8),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: w + 12,
                mainAxisSpacing: Ui.gap,
                crossAxisSpacing: Ui.gap,
                childAspectRatio: poster ? (w / (w * 1.5 + (Ui.tv ? 80 : 58))) : (w / (w * 9 / 16 + (Ui.tv ? 72 : 52))),
              ),
              delegate: SliverChildBuilderDelegate(
                (c, i) {
                  if (i >= items.length - 6) _next();
                  return ItemCard(items[i],
                      width: double.infinity,
                      poster: poster,
                      showSource: widget.showSource,
                      autofocus: Ui.tv && i == 0,
                      onTap: () => widget.onTap(items[i]),
                      onLongPress: widget.onLongPress == null ? null : () => widget.onLongPress!(items[i]));
                },
                childCount: items.length,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _loading
                ? const Loading()
                : _error != null
                    ? ErrorView(_error!, onRetry: _next, compact: true)
                    : SizedBox(height: Ui.tv ? 48 : 24),
          ),
        ],
      ]),
    );
  }
}

/// 一次載入的內容（作品頁、首頁的列）
class Loader<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T, VoidCallback reload) builder;
  final Widget? loading;
  const Loader({super.key, required this.load, required this.builder, this.loading});
  @override
  State<Loader<T>> createState() => _LoaderState<T>();
}

class _LoaderState<T> extends State<Loader<T>> {
  late Future<T> _f;
  @override
  void initState() {
    super.initState();
    _f = widget.load();
  }

  void _reload() => setState(() => _f = widget.load());

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _f,
        builder: (c, s) {
          if (s.hasError) return ErrorView(s.error!, onRetry: _reload);
          if (!s.hasData) return widget.loading ?? const Loading();
          return widget.builder(c, s.data as T, _reload);
        },
      );
}

/// 監聽 Listenable，變動就重畫
class Watch extends StatelessWidget {
  final Listenable listenable;
  final WidgetBuilder builder;
  const Watch(this.listenable, this.builder, {super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: listenable, builder: (c, _) => builder(c));
}

/// 防止連點
class Once {
  bool _busy = false;
  Future<void> run(Future<void> Function() f) async {
    if (_busy) return;
    _busy = true;
    try {
      await f();
    } finally {
      _busy = false;
    }
  }
}

Timer? debounceTimer;
