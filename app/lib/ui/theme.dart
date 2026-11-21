import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 設計 token（ui-ux-pro-max：Video Streaming / OTT → Dark Mode (OLED)，Cinema dark + play red）。
/// 只做深色：設計系統標明這個風格不建議淺色。
class C {
  static const bg = Color(0xFF000000);
  static const card = Color(0xFF0C0C0D);
  static const muted = Color(0xFF181818);
  static const raised = Color(0xFF222226);
  static const fg = Color(0xFFF8FAFC);
  static const mutedFg = Color(0xFF94A3B8);
  static const border = Color(0xFF2A2A31);
  static const accent = Color(0xFFE11D48);
  static const onAccent = Color(0xFFFFFFFF);
  static const ring = Color(0xFFFFFFFF);
  static const danger = Color(0xFFEF4444);
  static const success = Color(0xFF22C55E);
}

/// 尺寸：電視（10 呎介面）整體放大
class Ui {
  static bool tv = false;

  static double get gutter => tv ? 32 : 16;
  static double get gap => tv ? 16 : 12;
  static double get radius => tv ? 12 : 10;

  /// 卡片寬度：橫式（影片 16:9）、直式（海報、漫畫 2:3）
  static double get wideCard => tv ? 208 : 168;
  static double get posterCard => tv ? 132 : 112;

  static double get title => tv ? 24 : 20;
  static double get body => tv ? 17 : 15;
  static double get small => tv ? 14 : 13;
  static double get icon => tv ? 24 : 22;

  /// 動畫時間（尊重「減少動態」）
  static Duration dur(BuildContext c, [int ms = 160]) => MediaQuery.of(c).disableAnimations ? Duration.zero : Duration(milliseconds: ms);
}

ThemeData buildTheme({String? fontFamily}) {
  final base = ThemeData(
    fontFamily: fontFamily,
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: C.bg,
    canvasColor: C.bg,
    colorScheme: const ColorScheme.dark(
      primary: C.accent,
      onPrimary: C.onAccent,
      secondary: C.accent,
      surface: C.card,
      onSurface: C.fg,
      error: C.danger,
      outline: C.border,
    ),
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: C.fg, displayColor: C.fg),
    appBarTheme: const AppBarTheme(
      backgroundColor: C.bg,
      foregroundColor: C.fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle(statusBarColor: Colors.transparent, statusBarIconBrightness: Brightness.light),
    ),
    dividerTheme: const DividerThemeData(color: C.border, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: C.card,
      indicatorColor: C.accent.withValues(alpha: 0.18),
      height: 64,
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
            color: s.contains(WidgetState.selected) ? C.fg : C.mutedFg,
          )),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? C.accent : C.mutedFg, size: 22)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.muted,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: C.ring, width: 2)),
      hintStyle: const TextStyle(color: C.mutedFg),
      labelStyle: const TextStyle(color: C.mutedFg),
    ),
    snackBarTheme: const SnackBarThemeData(backgroundColor: C.raised, contentTextStyle: TextStyle(color: C.fg), behavior: SnackBarBehavior.floating),
    dialogTheme: const DialogThemeData(backgroundColor: C.card),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: C.card, showDragHandle: true),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.accent),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? C.muted : C.accent),
        foregroundColor: const WidgetStatePropertyAll(C.onAccent),
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? const BorderSide(color: C.ring, width: 3) : BorderSide.none),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll(C.fg),
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.focused) ? C.ring : C.border, width: s.contains(WidgetState.focused) ? 3 : 1)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll(C.fg),
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? const BorderSide(color: C.ring, width: 2) : BorderSide.none),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
        side: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) ? const BorderSide(color: C.ring, width: 2) : BorderSide.none),
      ),
    ),
    listTileTheme: const ListTileThemeData(iconColor: C.mutedFg, textColor: C.fg, minVerticalPadding: 10),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.onAccent : C.mutedFg),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.accent : C.muted),
    ),
  );
}
