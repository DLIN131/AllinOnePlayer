import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/model.dart';
import '../core/native.dart';
import '../core/registry.dart';
import '../core/sites.dart';
import 'theme.dart';
import 'widgets.dart';

/// 這個項目能不能預覽（影片站的作品）
bool canPreview(Item it) {
  final d = Sites.byKey[it.src];
  return d != null && d.kind == Kind.video && sources[it.src] != null;
}

/// 長按封面：跳出預覽框，靜音播放（有預覽短片的站播短片，其他站在正片裡跳著播）。
/// 按「播放」開作品；action 是呼叫端原本的長按功能（例如移除收藏），放成按鈕。
Future<void> showPreview(BuildContext context, Item item, {required VoidCallback onOpen, (String, VoidCallback)? action}) async {
  final open = await showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.78),
    builder: (_) => _PreviewDialog(item, action: action?.$1),
  );
  if (open == 'open') onOpen();
  if (open == 'action') action?.$2();
}

class _PreviewDialog extends StatefulWidget {
  final Item item;
  final String? action;
  const _PreviewDialog(this.item, {this.action});
  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  int? _texture;
  double _ratio = 16 / 9;
  bool _ready = false;
  String? _error;
  bool _closed = false;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = Native.events.listen(_onEvent);
    _start();
  }

  Future<void> _start() async {
    try {
      final p = await src(widget.item.src).preview(widget.item);
      await _play(p);
    } catch (e) {
      if (mounted) setState(() => _error = e is NetError ? e.message : '這部沒有預覽');
    }
  }

  Preview? _current;

  Future<void> _play(Preview p) async {
    if (_closed) return;
    _current = p;
    final id = await Native.previewStart(p);
    // 預覽框在開始播之前就被關掉了
    if (_closed) {
      unawaited(Native.previewStop());
      return;
    }
    setState(() {
      _texture = id;
      _ready = false;
    });
  }

  Future<void> _onEvent(Map e) async {
    if (e['type'] != 'preview' || e['id'] != _texture || !mounted) return;
    if (e['state'] == 'ready') {
      final w = (e['w'] as num?)?.toDouble() ?? 0, h = (e['h'] as num?)?.toDouble() ?? 0;
      setState(() {
        _ready = true;
        if (w > 0 && h > 0) _ratio = w / h;
      });
    } else if (e['state'] == 'error') {
      final fb = _current?.fallback;
      if (fb != null) {
        _current = null;
        try {
          await _play(await fb());
          return;
        } catch (_) {}
      }
      if (mounted) setState(() => _error = '這部沒有預覽（${e['message'] ?? ''}）');
    }
  }

  @override
  void dispose() {
    _closed = true;
    _sub?.cancel();
    unawaited(Native.previewStop());
    super.dispose();
  }

  /// 電視是按住 OK 打開預覽的：放開之前遙控器還會一直送 OK，不能讓它直接按到「開啟」
  bool _armed = false;

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (_armed) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final ok = k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter || k == LogicalKeyboardKey.gameButtonA;
    if (!ok) return KeyEventResult.ignored;
    if (e is KeyUpEvent) _armed = true;
    // 打開時已經放開的話，第一次按下就是使用者新按的
    if (e is KeyDownEvent) {
      _armed = true;
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: _dialog(context));

  Widget _dialog(BuildContext context) {
    final it = widget.item;
    // 畫面矮（電視、手機橫放）時影片框跟著縮，標題和按鈕才放得下
    final room = MediaQuery.sizeOf(context).height - Ui.gutter * 2 - (Ui.tv ? 150 : 170);
    final maxW = [Ui.tv ? 720.0 : 560.0, room * 16 / 9].reduce((a, b) => a < b ? a : b);
    return Dialog(
      backgroundColor: C.card,
      insetPadding: EdgeInsets.all(Ui.gutter),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ui.radius + 4)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(fit: StackFit.expand, children: [
              Container(color: Colors.black),
              // 短片出來之前先顯示封面
              if (!_ready) Cover(it.cover, site: it.src),
              if (_texture != null)
                Opacity(
                  opacity: _ready ? 1 : 0,
                  child: Center(child: AspectRatio(aspectRatio: _ratio, child: Texture(textureId: _texture!))),
                ),
              if (!_ready && _error == null) const Center(child: CircularProgressIndicator(color: C.accent)),
              if (_error != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(6)),
                    child: Text(_error!, style: TextStyle(color: C.fg, fontSize: Ui.small)),
                  ),
                ),
              Positioned(
                left: 8,
                top: 8,
                child: Row(children: [
                  SourceBadge(it.src),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.72), borderRadius: BorderRadius.circular(6)),
                    child: Row(children: [
                      Icon(LucideIcons.volumeX, size: Ui.tv ? 16 : 12, color: C.mutedFg),
                      const SizedBox(width: 4),
                      Text('預覽', style: TextStyle(fontSize: Ui.tv ? 14 : 10, color: C.mutedFg)),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(Ui.gap, Ui.gap, Ui.gap, 4),
            child: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Ui.body, fontWeight: FontWeight.w600, height: 1.4)),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(Ui.gap, 4, Ui.gap, Ui.gap),
            child: Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.end, children: [
              if (widget.action != null)
                OutlinedButton(onPressed: () => Navigator.pop(context, 'action'), child: Text(widget.action!)),
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('關閉')),
              FilledButton.icon(
                autofocus: true,
                onPressed: () => Navigator.pop(context, 'open'),
                icon: const Icon(LucideIcons.play),
                label: const Text('開啟'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
