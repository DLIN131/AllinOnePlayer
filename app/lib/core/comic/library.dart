import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../model.dart';
import '../store.dart';
import 'cbz.dart';
import 'comic_downloads.dart';

/// 書櫃裡的一本（本機的 CBZ / ZIP）
class Book {
  final String path;
  final String title;
  final int pages;
  final int size;
  final int modified;
  const Book(this.path, this.title, this.pages, this.size, this.modified);

  String get name => path.split(RegExp(r'[\\/]')).last;

  /// 閱讀進度、紀錄用的項目
  Item get item => Item(src: 'local', id: name, title: title, cover: 'cbz:$path#0', sub: '$pages 頁', type: 'comic', poster: true);
}

/// 合集：好幾本當成一本連續讀（只是記錄，不動檔案）
class Collection {
  final String id;
  String name;
  List<String> files; // 書的檔名
  String cover;
  Collection(this.id, this.name, this.files, [this.cover = '']);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'files': files, 'cover': cover};
  factory Collection.fromJson(Map j) => Collection('${j['id']}', '${j['name'] ?? ''}', [for (final f in (j['files'] as List? ?? const [])) '$f'], '${j['cover'] ?? ''}');
}

/// 書櫃：下載資料夾裡的漫畫檔＋使用者從手機加進來的檔案
class Library extends ChangeNotifier {
  static final Library instance = Library._();
  Library._();

  List<Book> books = [];
  bool loading = false;
  final _covers = <String, Uint8List>{};
  final _readers = <String, CbzReader>{};

  static String get dir => ComicDownloads.dir;

  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    final out = <Book>[];
    final d = Directory(dir);
    if (await d.exists()) {
      await for (final f in d.list()) {
        if (f is! File || !RegExp(r'\.(cbz|zip)$', caseSensitive: false).hasMatch(f.path)) continue;
        try {
          final st = await f.stat();
          final r = reader(f.path);
          final info = r.comicInfo;
          var title = comicInfoField(info, 'Title');
          if (title.isEmpty) title = f.path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.(cbz|zip)$', caseSensitive: false), '');
          out.add(Book(f.path, title, r.pages.length, st.size, st.modified.millisecondsSinceEpoch));
        } catch (_) {
          // 讀不了的檔（下載到一半、壞掉）先跳過
        }
      }
    }
    out.sort((a, b) => b.modified.compareTo(a.modified));
    books = out;
    loading = false;
    notifyListeners();
  }

  CbzReader reader(String path) {
    final r = _readers[path];
    if (r != null) return r;
    // 最多同時開 6 個檔
    if (_readers.length >= 6) {
      final k = _readers.keys.first;
      _readers.remove(k)?.close();
    }
    return _readers[path] = CbzReader.open(path);
  }

  Uint8List page(String path, int index) => reader(path).page(index);

  Uint8List? cover(String path) {
    final c = _covers[path];
    if (c != null) return c;
    try {
      final r = reader(path);
      if (r.pages.isEmpty) return null;
      return _covers[path] = r.page(0);
    } catch (_) {
      return null;
    }
  }

  /// 從手機選的檔案複製進書櫃資料夾
  Future<int> import(List<String> paths) async {
    await Directory(dir).create(recursive: true);
    var n = 0;
    for (final p in paths) {
      try {
        final name = p.split(RegExp(r'[\\/]')).last;
        await File(p).copy('$dir/$name');
        n++;
      } catch (_) {}
    }
    await refresh();
    return n;
  }

  Future<void> delete(Book b) async {
    _readers.remove(b.path)?.close();
    _covers.remove(b.path);
    try {
      await File(b.path).delete();
    } catch (_) {}
    final cols = collections;
    for (final c in cols) {
      c.files.remove(b.name);
    }
    _saveCollections(cols);
    await refresh();
  }

  // ---------- 合集 ----------

  List<Collection> get collections {
    final raw = Store.instance.raw('collections');
    return raw is List ? [for (final c in raw) if (c is Map) Collection.fromJson(c)] : [];
  }

  void _saveCollections(List<Collection> cols) {
    Store.instance.setRaw('collections', [for (final c in cols) c.toJson()]);
    notifyListeners();
  }

  Collection? collectionOf(String bookName) => collections.where((c) => c.files.contains(bookName)).firstOrNull;

  Collection createCollection(String name, List<String> files) {
    final cols = collections;
    // 一本書只屬於一個合集
    for (final c in cols) {
      c.files.removeWhere(files.contains);
    }
    final c = Collection('${DateTime.now().millisecondsSinceEpoch}', name, List.of(files));
    cols.add(c);
    _saveCollections(cols);
    return c;
  }

  void updateCollection(Collection c) {
    final cols = collections;
    final i = cols.indexWhere((e) => e.id == c.id);
    if (i >= 0) cols[i] = c;
    _saveCollections(cols);
  }

  void deleteCollection(String id) => _saveCollections(collections..removeWhere((c) => c.id == id));

  List<Book> booksOf(Collection c) => [for (final f in c.files) ...books.where((b) => b.name == f)];
}
