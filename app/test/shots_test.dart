// 截圖：用真的網站資料把主要畫面畫成 PNG（代替模擬器看排版）。只在 SHOTS=1 時跑。
//   SHOTS=1 FONT=<中文字型 .ttf> OUT=<輸出資料夾> flutter test test/shots_test.dart
// 有 Cloudflare 的站（一般 HTTP 連不上）在首頁先隱藏。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:allinoneplayer/core/model.dart';
import 'package:allinoneplayer/core/native.dart';
import 'package:allinoneplayer/core/registry.dart';
import 'package:allinoneplayer/core/sites.dart';
import 'package:allinoneplayer/core/store.dart';
import 'package:allinoneplayer/ui/app.dart';
import 'package:allinoneplayer/ui/pages/detail_page.dart';
import 'package:allinoneplayer/ui/pages/library_page.dart';
import 'package:allinoneplayer/ui/pages/sources_page.dart';
import 'package:allinoneplayer/ui/theme.dart';
import 'package:allinoneplayer/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final env = Platform.environment;
final enabled = env['SHOTS'] == '1';
final out = env['OUT'] ?? 'build/shots';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpClient client;

  setUpAll(() async {
    HttpOverrides.global = null;
    client = HttpClient();
    final images = <String, Future<Uint8List>>{};
    Cover.testLoader = (url, headers) => images[url] ??= Zone.root.run(() async {
          final req = await client.getUrl(Uri.parse(url));
          req.headers.set('User-Agent', Native.info.userAgent);
          headers.forEach(req.headers.set);
          final res = await req.close();
          final b = BytesBuilder();
          await for (final c in res) {
            b.add(c);
          }
          return b.takeBytes();
        });
    Native.info = DeviceInfo.fake();
    final font = FontLoader('NotoSansTC')..addFont(File(env['FONT']!).readAsBytes().then((b) => ByteData.view(b.buffer)));
    await font.load();
    final lucideDir = Directory('${env['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev').listSync().whereType<Directory>().where((d) => d.path.contains('lucide_icons_flutter-4')).last;
    final icons = FontLoader('packages/lucide_icons_flutter/Lucide')..addFont(File('${lucideDir.path}/assets/lucide.ttf').readAsBytes().then((b) => ByteData.view(b.buffer)));
    await icons.load();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('aio/native'), (call) async {
      if (call.method == 'fetch') return Zone.root.run(() async {
        final a = Map<String, dynamic>.from(call.arguments as Map);
        final req = await client.openUrl(a['method'] as String, Uri.parse(a['url'] as String));
        req.headers.set('User-Agent', Native.info.userAgent);
        req.headers.set('Referer', '${Sites.base(a['site'] as String)}/');
        final res = await req.close();
        return {'status': res.statusCode, 'url': a['url'], 'text': await res.transform(utf8.decoder).join()};
      });
      return null;
    });
    Directory(out).createSync(recursive: true);
  });

  Future<void> shot(WidgetTester t, String name, Widget page, {required bool tv, Duration wait = const Duration(seconds: 6)}) async {
    Ui.tv = tv;
    Native.info = DeviceInfo.fake(isTv: tv);
    final size = tv ? const Size(960, 540) : const Size(411, 891);
    t.view.physicalSize = size * (tv ? 2 : 2.625);
    t.view.devicePixelRatio = tv ? 2 : 2.625;
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(fontFamily: 'NotoSansTC'), home: page),
    ));
    for (var i = 0; i < wait.inMilliseconds ~/ 500; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
      await t.pump(const Duration(milliseconds: 100));
    }
    // 等圖片解碼
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 400)));
      await t.pump(const Duration(milliseconds: 50));
    }
    await t.runAsync(() async {
      final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: tv ? 2 : 2.625);
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$out/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
    // ignore: avoid_print
    print('已存 $out/$name.png');
  }

  Future<List<Item>> sample() async {
    final r = await src('vc').list({'section': 'videos'}, 1);
    final c = await src('nh').list({'section': 'latest'}, 1);
    return [...r.items.take(4), ...c.items.take(4)];
  }

  testWidgets('手機：主畫面', (t) async {
    final items = (await t.runAsync(sample))!;
    Store.instance.loadMemory({
      'settings': {'homeHidden': ['va', 'vb', 'jm']},
      'favorites': [for (final i in items) {'item': i.toJson(), 't': 0}],
      'history': [
        {'item': items[0].toJson(), 't': 1, 'pos': 300000, 'dur': 1200000},
        {'item': items[5].toJson(), 't': 0, 'page': 7, 'total': 24},
      ],
    });
    await shot(t, 'phone_home', const Shell(), tv: false);
    await shot(t, 'phone_sources', const Scaffold(body: SafeArea(child: SourcesPage())), tv: false, wait: const Duration(seconds: 1));
    await shot(t, 'phone_source_vc', const SourcePage('vc'), tv: false);
    await shot(t, 'phone_detail_video', DetailPage(items[0]), tv: false);
    await shot(t, 'phone_detail_comic', DetailPage(items[4]), tv: false);
    await shot(t, 'phone_library', const Scaffold(body: SafeArea(child: LibraryPage())), tv: false, wait: const Duration(seconds: 1));
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('電視：主畫面', (t) async {
    final items = (await t.runAsync(sample))!;
    Store.instance.loadMemory({
      'settings': {'homeHidden': ['va', 'vb', 'jm']},
      'history': [
        {'item': items[0].toJson(), 't': 1, 'pos': 300000, 'dur': 1200000},
      ],
    });
    await shot(t, 'tv_home', const Shell(), tv: true);
    await shot(t, 'tv_detail_video', DetailPage(items[0]), tv: true);
    await shot(t, 'tv_detail_comic', DetailPage(items[4]), tv: true);
  }, skip: !enabled, timeout: const Timeout(Duration(minutes: 5)));
}
