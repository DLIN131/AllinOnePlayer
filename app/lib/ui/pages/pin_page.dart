import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/pin_lock.dart';
import '../theme.dart';
import '../widgets.dart';

/// 數字鍵盤（觸控、遙控器方向鍵＋OK、遙控器數字鍵都能用）
class PinPad extends StatefulWidget {
  final int length;
  final String title;
  final String? message;
  final bool error;
  final ValueChanged<String> onDone;
  final Widget? footer;
  const PinPad({super.key, this.length = 4, required this.title, this.message, this.error = false, required this.onDone, this.footer});
  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String value = '';

  void _add(String d) {
    if (value.length >= widget.length) return;
    setState(() => value += d);
    if (value.length == widget.length) {
      final v = value;
      Future.delayed(const Duration(milliseconds: 120), () {
        if (!mounted) return;
        setState(() => value = '');
        widget.onDone(v);
      });
    }
  }

  void _del() {
    if (value.isNotEmpty) setState(() => value = value.substring(0, value.length - 1));
  }

  KeyEventResult _key(FocusNode n, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final l = e.logicalKey.keyLabel;
    if (RegExp(r'^\d$').hasMatch(l)) {
      _add(l);
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.backspace || e.logicalKey == LogicalKeyboardKey.delete) {
      _del();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final size = Ui.tv ? 84.0 : 72.0;
    Widget key(String label, VoidCallback onTap, {bool autofocus = false, IconData? icon}) => Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: size,
            height: size,
            child: Tap(
              radius: size / 2,
              autofocus: autofocus,
              semanticLabel: icon != null ? '刪除' : label,
              onTap: onTap,
              child: Container(
                decoration: const BoxDecoration(color: C.muted, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: icon != null ? Icon(icon, size: Ui.icon) : Text(label, style: TextStyle(fontSize: Ui.title, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        );
    return Focus(
      onKeyEvent: _key,
      child: Center(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(LucideIcons.lock, size: Ui.tv ? 44 : 36, color: C.accent),
            const SizedBox(height: 12),
            Text(widget.title, style: TextStyle(fontSize: Ui.title - 2, fontWeight: FontWeight.w700)),
            if (widget.message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Text(widget.message!, textAlign: TextAlign.center, style: TextStyle(color: widget.error ? C.danger : C.mutedFg, fontSize: Ui.small, height: 1.5)),
              ),
            const SizedBox(height: 18),
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < widget.length; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 7),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: i < value.length ? C.fg : Colors.transparent, border: Border.all(color: C.mutedFg, width: 2)),
                ),
            ]),
            const SizedBox(height: 18),
            for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
              Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d, () => _add(d), autofocus: d == '5')]),
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: size + 12),
              key('0', () => _add('0')),
              key('', _del, icon: LucideIcons.delete),
            ]),
            if (widget.footer != null) Padding(padding: const EdgeInsets.only(top: 12), child: widget.footer!),
          ]),
        ),
      ),
    );
  }
}

/// 解鎖畫面
class PinGate extends StatefulWidget {
  final VoidCallback onUnlocked;
  const PinGate({super.key, required this.onUnlocked});
  @override
  State<PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<PinGate> {
  String? msg;
  bool err = false;
  bool recovery = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (PinLock.lockedSeconds > 0 && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  String? get lockMsg {
    final s = PinLock.lockedSeconds;
    return s > 0 ? '錯太多次了，請 $s 秒後再試' : null;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: PinPad(
          key: ValueKey(recovery),
          length: recovery ? 8 : 4,
          title: recovery ? '輸入 8 位數救援碼' : '輸入密碼',
          message: lockMsg ?? msg,
          error: err || lockMsg != null,
          onDone: (v) {
            if (PinLock.lockedSeconds > 0) return setState(() {});
            if (recovery) {
              final code = PinLock.recover(v);
              if (code == null) {
                setState(() {
                  err = true;
                  msg = '救援碼不對';
                });
                return;
              }
              showDialog(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('已解鎖'),
                  content: Text('舊的救援碼已作廢，新的救援碼是：\n\n$code\n\n請抄下來。建議到「我的 › 開啟密碼」改一個新密碼。', style: TextStyle(fontSize: Ui.body, height: 1.5)),
                  actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('記下了'))],
                ),
              ).then((_) => widget.onUnlocked());
              return;
            }
            if (PinLock.check(v)) {
              widget.onUnlocked();
            } else {
              setState(() {
                err = true;
                final left = PinLock.freeTries - PinLock.failures;
                msg = left > 0 ? '密碼不對（還可以試 $left 次）' : '密碼不對';
              });
            }
          },
          footer: TextButton(
            onPressed: () => setState(() {
              recovery = !recovery;
              msg = null;
              err = false;
            }),
            child: Text(recovery ? '改用密碼' : '忘記密碼？用救援碼', style: TextStyle(color: C.mutedFg, fontSize: Ui.small)),
          ),
        ),
      );
}

/// 設定 / 更換 / 關閉密碼
class PinSettingsPage extends StatefulWidget {
  const PinSettingsPage({super.key});
  @override
  State<PinSettingsPage> createState() => _PinSettingsPageState();
}

class _PinSettingsPageState extends State<PinSettingsPage> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('開啟密碼')),
        body: ListView(padding: EdgeInsets.all(Ui.gutter), children: [
          Text('開啟後，每次打開 App（或離開超過 1 分鐘再回來）都要輸入 4 位數密碼。忘記密碼時可以用 8 位數救援碼解鎖。',
              style: TextStyle(color: C.mutedFg, fontSize: Ui.small, height: 1.5)),
          const SizedBox(height: 16),
          if (!PinLock.enabled)
            FilledButton.icon(autofocus: true, onPressed: _setNew, icon: const Icon(LucideIcons.lock), label: const Text('設定密碼'))
          else ...[
            OutlinedButton(autofocus: true, onPressed: _setNew, child: const Text('更換密碼')),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                if (!await _verify()) return;
                final code = PinLock.newRecoveryCode();
                if (mounted) await _showCode(code);
              },
              child: const Text('產生新的救援碼'),
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: () async {
                if (!await _verify()) return;
                PinLock.disable();
                if (mounted) {
                  setState(() {});
                  toast(context, '已關閉開啟密碼');
                }
              },
              child: const Text('關閉密碼'),
            ),
          ],
        ]),
      );

  Future<bool> _verify() async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => PinGate(onUnlocked: () => Navigator.of(context).pop(true))));
    return ok == true;
  }

  Future<void> _setNew() async {
    if (PinLock.enabled && !await _verify()) return;
    if (!mounted) return;
    final first = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (c) => Scaffold(body: PinPad(title: '設定 4 位數密碼', onDone: (v) => Navigator.pop(c, v)))));
    if (first == null || !mounted) return;
    final second = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (c) => Scaffold(body: PinPad(title: '再輸入一次', onDone: (v) => Navigator.pop(c, v)))));
    if (second == null || !mounted) return;
    if (first != second) {
      toast(context, '兩次輸入的不一樣，請重新設定');
      return;
    }
    final code = PinLock.setPin(first);
    setState(() {});
    await _showCode(code);
  }

  Future<void> _showCode(String code) => showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('救援碼'),
          content: Text('忘記密碼時用這組救援碼解鎖：\n\n$code\n\n請抄下來，之後不會再顯示。', style: TextStyle(fontSize: Ui.body, height: 1.5)),
          actions: [FilledButton(autofocus: true, onPressed: () => Navigator.pop(c), child: const Text('記下了'))],
        ),
      );
}
