// 連真的網站測解析器（只在環境變數 LIVE=1 時跑）。
// 原生層用 dart:io 模擬（一般 HTTP，帶 UA 和 Referer）；有 Cloudflare 的站（va、vb、jm）這樣連不上，不在這裡測。
import 'dart:convert';
import 'dart:io';

import 'package:allinoneplayer/core/model.dart';
import 'package:allinoneplayer/core/native.dart';
import 'package:allinoneplayer/core/registry.dart';
import 'package:allinoneplayer/core/sites.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final live = Platform.environment['LIVE'] == '1';
final only = Platform.environment['SITES']?.split(',');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpClient client;
  setUpAll(() {
    // flutter_test 預設把網路換成假的（都回 400），這裡要真的連線
    HttpOverrides.global = null;
    client = HttpClient();
    Native.info = DeviceInfo.fake();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('aio/native'), (call) async {
      if (call.method != 'fetch') return null;
      final a = Map<String, dynamic>.from(call.arguments as Map);
      final url = a['url'] as String;
      final site = a['site'] as String;
      final req = await client.openUrl(a['method'] as String, Uri.parse(url));
      req.headers.set('User-Agent', Native.info.userAgent);
      req.headers.set('Referer', '${Sites.base(site)}/');
      (a['headers'] as Map?)?.forEach((k, v) => req.headers.set('$k', '$v'));
      if (a['body'] != null) req.write(a['body']);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      return {'status': res.statusCode, 'url': url, 'text': text};
    });
  });

  bool want(String k) => live && (only == null || only!.contains(k));

  for (final k in ['vc', 'nh', 'wn', 'eh']) {
    test('$k：列表 → 作品頁', () async {
      final s = src(k);
      final first = s.sections.firstWhere((x) => !x.shelves && x.id != 'fav');
      final page = await s.list({'section': first.id}, 1);
      // ignore: avoid_print
      print('$k 列表 ${page.items.length} 筆，hasMore=${page.hasMore}，第一筆：${page.items.firstOrNull?.title}');
      expect(page.items, isNotEmpty);
      final it = page.items.first;
      expect(it.title, isNotEmpty);
      expect(it.cover, startsWith('http'));
      final d = await s.detail(it);
      // ignore: avoid_print
      print('$k 作品頁：${d.title}｜資訊 ${d.info.length} 列｜標籤 ${d.tags.length}｜集數 ${d.episodes.length}｜相關 ${d.related.length}');
      expect(d.title, isNotEmpty);
      if (s.isComic) {
        final pages = await s.read(d, d.chapters.isEmpty ? null : d.chapters.first.id);
        // ignore: avoid_print
        print('$k 閱讀頁 ${pages.length} 張，第一張：${pages.first.url.isEmpty ? '(要再解析)' : pages.first.url}');
        expect(pages, isNotEmpty);
        if (pages.first.resolve != null) expect(await pages.first.resolve!(false), startsWith('http'));
      } else {
        final st = await s.stream(d);
        expect(st.url, startsWith('http'));
      }
    }, skip: !want(k), timeout: const Timeout(Duration(minutes: 2)));
  }

  test('vc：首頁區塊、分類、搜尋', () async {
    final s = src('vc');
    final home = await s.shelves('home');
    // ignore: avoid_print
    print('vc 首頁：${home.map((e) => '${e.title}(${e.items.length})').join('、')}');
    expect(home, isNotEmpty);
    final cats = await s.shelves('cats');
    expect(cats, isNotEmpty);
    final series = await s.list({'section': 'series'}, 1);
    expect(series.items.first.type, 'series');
    final sd = await s.detail(series.items.first);
    // ignore: avoid_print
    print('vc 劇集：${sd.title}，${sd.episodes.length} 集');
    expect(sd.episodes, isNotEmpty);
    final r = await s.search(home.first.items.first.title.substring(0, 2), 1, const {});
    expect(r.items, isNotEmpty);
  }, skip: !want('vc'), timeout: const Timeout(Duration(minutes: 2)));

  test('nh：搜尋', () async {
    final r = await src('nh').search('language:chinese', 1, const {});
    expect(r.items, isNotEmpty);
    expect(r.items.where((e) => e.lang == 'zh').length, greaterThan(r.items.length ~/ 2));
  }, skip: !want('nh'));
}

Item fake(String src, String id) => Item(src: src, id: id, title: id, cover: '');
