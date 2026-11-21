import 'package:flutter/material.dart';

import '../core/comic/library.dart';
import '../core/model.dart';
import '../core/registry.dart';
import 'pages/detail_page.dart';
import 'pages/list_page.dart';
import 'pages/reader_page.dart';

Future<T?> push<T>(BuildContext c, Widget page) => Navigator.of(c).push<T>(MaterialPageRoute(builder: (_) => page));

/// 打開一個項目：女優 → 她的作品列表；本機漫畫 → 直接閱讀；其他 → 作品頁
void openItem(BuildContext c, Item it) {
  if (it.type == 'actress') {
    push(c, ListPage(link: va.actressLink(it.title, it.id)));
  } else if (it.src == 'local') {
    final book = Library.instance.books.where((b) => b.name == it.id).firstOrNull;
    if (book != null) push(c, ReaderPage.book(book));
  } else {
    push(c, DetailPage(it));
  }
}

void openLink(BuildContext c, Link l) {
  if (l.params['section'] == 'openSeries') {
    push(c, DetailPage(Item(src: l.src, id: l.params['id']!, title: l.title, cover: '', type: 'series', poster: true)));
  } else {
    push(c, ListPage(link: l));
  }
}
