import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:allinoneplayer/core/comic/cbz.dart';
import 'package:allinoneplayer/core/comic/descramble.dart';
import 'package:allinoneplayer/core/sources/comic_common.dart';
import 'package:allinoneplayer/core/sources/jm.dart';
import 'package:allinoneplayer/core/sources/tsr.dart';
import 'package:allinoneplayer/core/sources/va.dart';
import 'package:allinoneplayer/core/updater.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('頁面資料（TSR）', () {
    String page(String data) => r'<script>$_TSR.router=($R=>$R[0]={matches:$R[1]=[$R[2]={i:"__root__",l:null},$R[3]={i:"x",l:' + data + r'}]})($R["tsr"])</script>';

    test('值與參照', () {
      final d = Tsr.pageData(page(r'$R[4]={ads:$R[5]={a:1},list:$R[6]=[$R[7]={id:"a",n:1.5,ok:!0,no:!1,x:null,tags:$R[8]=["中文"]},$R[7]],s:"q\"中\x41\n",e:-2e3,"/k/":1}'))!;
      expect(d['ads'], isNull);
      final list = d['list'] as List;
      expect(list.length, 2);
      expect((list[1] as Map)['id'], 'a');
      expect((list[0] as Map)['n'], 1.5);
      expect((list[0] as Map)['ok'], true);
      expect((list[0] as Map)['no'], false);
      expect((list[0] as Map)['tags'], ['中文']);
      expect(d['s'], 'q"中A\n');
      expect(d['e'], -2000.0);
      expect(d['/k/'], 1.0);
    });

    test('沒有資料回傳 null', () => expect(Tsr.pageData('<html></html>'), isNull));
  });

  group('va', () {
    // 影片頁裡打包過的播放網址片段（原樣，含跳脫字元）
    const packed = r"""
        let source
        eval(function(p,a,c,k,e,d){e=function(c){return c.toString(36)};if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c])}}return p}('e=\'8://7.6/5-4-3-2-1/d.0\';c=\'8://7.6/5-4-3-2-1/a/9.0\';b=\'8://7.6/5-4-3-2-1/a/9.0\';',15,15,'m3u8|c9447e4618dd|a535|438d|4e30|362737b8|com|cdn|https|video|720p|source1280|source842|playlist|source'.split('|'),0,{}))
        const video = document.querySelector('video.player')
    """;

    test('解開打包的播放網址', () {
      expect(VaSource.findPlaylist(packed), 'https://cdn.com/362737b8-4e30-438d-a535-c9447e4618dd/playlist.m3u8');
    });

    test('個人頁看得出登入帳號', () {
      const loggedIn = '''
        <button @click.prevent="showDropdown = 'user'" class="group inline-flex items-center">
        <div class="px-4 py-3">
            <p class="text-sm leading-5 text-nord0">
                登入為
            </p>
            <p class="text-sm leading-5 font-medium text-nord0 truncate">
                someone@example.com
            </p>
        </div>''';
      expect(VaAccount.parseLoginEmail(loggedIn), 'someone@example.com');
      expect(VaAccount.parseLoginEmail('<a @click.prevent="showLoginModal()">登入</a>'), isNull);
    });

    String article(String code, List<String> names) => '''
        <article class="archive-list"><header class="archive-header">
          <ul class="post-meta clearfix">
            ${names.map((n) => '<li class="actress-name"><a href="https://example.com/a/$n/">$n</a></li>').join()}
            <li><a href="https://example.com/series/">series</a></li>
            <li>$code</li>
          </ul>
        </header></article>''';

    test('番號查女優只留對得上的', () {
      expect(VaLookup.parse('<main>${article('ABCD-5000', ['甲'])}${article('ABCD-50001', ['乙'])}</main>', 'abcd-5000').map((e) => e.$1), ['甲']);
      expect(VaLookup.parse('<main>${article('259WXYZ-1800', ['丙', '丁'])}</main>', 'wxyz-1800').map((e) => e.$1), ['丙', '丁']);
      expect(VaLookup.normalize('abcd-457-uncensored-leak'), 'ABCD-457');
      expect(VaLookup.normalize('abcd-359-chinese-subtitle'), 'ABCD-359');
      expect(VaLookup.parse('<main>0</main>', 'ZZZZ-999'), isEmpty);
    });
  });

  group('漫畫', () {
    test('jm 切條數（跟 md5 規則一致）', () {
      expect(JmSource.segments(220980, 100, '00001'), 0);
      expect(JmSource.segments(220980, 250000, '00001'), 10);
      final n = JmSource.segments(220980, 500000, '00001');
      expect(n >= 2 && n <= 16 && n.isEven, true);
    });

    test('切條還原的位置', () {
      // 高 10、切 3 條：多出來的 1 行給第一條
      expect(strips(10, 3), [(6, 0, 4), (3, 4, 3), (0, 7, 3)]);
      var covered = 0;
      for (final (_, _, h) in strips(1234, 10)) {
        covered += h;
      }
      expect(covered, 1234);
    });

    test('編號搜尋', () {
      expect(Query.parseId('JM350234')?.sites, ['jm']);
      expect(Query.parseId('#177013')?.sites, ['nh']);
      expect(Query.parseId('123456')?.plain, true);
      expect(Query.parseId('隨便的字'), isNull);
    });

    test('作者、書名整理', () {
      expect(Query.parseAuthors('(C99) [社團 (作者甲)] 書名 [中國翻譯]'), ['作者甲', '社團']);
      expect(Query.cleanTitle('(C99) [社團 (作者甲)] 書名 [中國翻譯]'), '書名');
      expect(Lang.detect(['[Chinese] abc']), 'zh');
    });

    test('CBZ 寫入後讀得回來（含中文檔名）', () async {
      final dir = await Directory.systemTemp.createTemp('aio');
      final path = '${dir.path}/測試.cbz';
      final w = await CbzWriter.create(path);
      await w.add('0002.jpg', Uint8List.fromList([2, 2]));
      await w.add('0010.jpg', Uint8List.fromList([10]));
      await w.add('0001.jpg', Uint8List.fromList([1, 1, 1]));
      await w.add('ComicInfo.xml', utf8.encode(comicInfoXml(title: '書 & <名>', pages: 3)));
      await w.close();
      final r = CbzReader.open(path);
      expect(r.pages.map((p) => p.name), ['0001.jpg', '0002.jpg', '0010.jpg']);
      expect(r.page(0), [1, 1, 1]);
      expect(comicInfoField(r.comicInfo, 'Title'), '書 & <名>');
      r.close();
      await dir.delete(recursive: true);
    });
  });

  test('更新說明解析', () {
    final r = Release.fromJson({
      'tag_name': 'v1.0.12',
      'body': '新增功能\n- 第一點\n- 第二點\n\nCo-Authored-By: x\n---\n固定網址',
      'published_at': '2026-11-21T00:00:00Z',
      'assets': [
        {'name': 'AllinOnePlayer.apk', 'browser_download_url': 'https://x/a.apk'},
      ],
    });
    expect(r.build, 12);
    expect(r.title, '新增功能');
    expect(r.notes, ['第一點', '第二點']);
    expect(r.assets['AllinOnePlayer.apk'], 'https://x/a.apk');
  });
}
