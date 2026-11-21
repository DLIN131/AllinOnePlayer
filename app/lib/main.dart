import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/auth.dart';
import 'core/comic/comic_downloads.dart';
import 'core/native.dart';
import 'core/playback.dart';
import 'core/sites.dart';
import 'core/sources/comic_common.dart';
import 'core/store.dart';
import 'ui/app.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Native.init();
  Ui.tv = Native.info.isTv;
  await Store.instance.load(Native.info.filesDir);

  // 使用者改過的網站網址、漫畫語言篩選
  final urls = Store.instance.setting<Map>('siteUrls', const {});
  urls.forEach((k, v) => Sites.overrides['$k'] = '$v');
  Lang.filter = Store.instance.setting<String>('lang', '');
  await Native.configure(Sites.nativeConfig());

  Auth.init();
  ComicDownloads.instance.load();
  if (!Ui.tv) VideoDownloads.instance.init();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: C.card,
    statusBarIconBrightness: Brightness.light,
  ));
  if (Ui.tv) SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const AioApp());
}
