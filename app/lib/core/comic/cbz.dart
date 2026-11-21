import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 漫畫檔（CBZ = ZIP，圖片不壓縮）。邊下載邊寫，寫到一半當機也只是少了尾巴（重新下載會覆蓋）。
class CbzWriter {
  final RandomAccessFile _f;
  final _entries = <(String, int, int, int)>[]; // (名稱, crc, 大小, 位置)
  int _pos = 0;

  CbzWriter._(this._f);

  static Future<CbzWriter> create(String path) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    return CbzWriter._(await f.open(mode: FileMode.write));
  }

  Future<void> add(String name, List<int> data) async {
    final nameBytes = Uint8List.fromList(utf8.encode(name));
    final crc = getCrc32(data);
    final h = BytesBuilder();
    h.add(_u32(0x04034b50));
    h.add(_u16(20)); // 版本
    h.add(_u16(0x0800)); // UTF-8 檔名
    h.add(_u16(0)); // 不壓縮
    h.add(_u16(0));
    h.add(_u16(0x21)); // 1980-01-01
    h.add(_u32(crc));
    h.add(_u32(data.length));
    h.add(_u32(data.length));
    h.add(_u16(nameBytes.length));
    h.add(_u16(0));
    h.add(nameBytes);
    final header = h.toBytes();
    await _f.writeFrom(header);
    await _f.writeFrom(data);
    _entries.add((name, crc, data.length, _pos));
    _pos += header.length + data.length;
  }

  Future<void> close() async {
    final start = _pos;
    final cd = BytesBuilder();
    for (final (name, crc, size, off) in _entries) {
      final nameBytes = Uint8List.fromList(utf8.encode(name));
      cd.add(_u32(0x02014b50));
      cd.add(_u16(20));
      cd.add(_u16(20));
      cd.add(_u16(0x0800));
      cd.add(_u16(0));
      cd.add(_u16(0));
      cd.add(_u16(0x21));
      cd.add(_u32(crc));
      cd.add(_u32(size));
      cd.add(_u32(size));
      cd.add(_u16(nameBytes.length));
      cd.add(_u16(0));
      cd.add(_u16(0));
      cd.add(_u16(0));
      cd.add(_u16(0));
      cd.add(_u32(0));
      cd.add(_u32(off));
      cd.add(nameBytes);
    }
    final dir = cd.toBytes();
    final end = BytesBuilder()
      ..add(_u32(0x06054b50))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(_entries.length))
      ..add(_u16(_entries.length))
      ..add(_u32(dir.length))
      ..add(_u32(start))
      ..add(_u16(0));
    await _f.writeFrom(dir);
    await _f.writeFrom(end.toBytes());
    await _f.close();
  }

  static Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
  static Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v & 0xFFFFFFFF, Endian.little);
}

/// 讀漫畫檔：圖片依檔名排序（數字照大小排）
class CbzReader {
  final String path;
  final Archive _archive;
  final InputFileStream _input;
  late final List<ArchiveFile> pages;
  late final String? comicInfo;

  CbzReader._(this.path, this._archive, this._input) {
    final imgs = _archive.files.where((f) => f.isFile && RegExp(r'\.(jpe?g|png|webp|gif|avif|bmp)$', caseSensitive: false).hasMatch(f.name)).toList();
    imgs.sort((a, b) => naturalCompare(a.name, b.name));
    pages = imgs;
    final info = _archive.files.where((f) => f.name.toLowerCase().endsWith('comicinfo.xml')).firstOrNull;
    comicInfo = info == null ? null : utf8.decode(info.readBytes() ?? const [], allowMalformed: true);
  }

  static CbzReader open(String path) {
    final input = InputFileStream(path);
    return CbzReader._(path, ZipDecoder().decodeStream(input), input);
  }

  Uint8List page(int i) => pages[i].readBytes() ?? Uint8List(0);

  void close() => _input.close();
}

/// 自然排序：page2 在 page10 前面
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final x = re.allMatches(a.toLowerCase()).toList(), y = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final p = x[i].group(0)!, q = y[i].group(0)!;
    final n = int.tryParse(p), m = int.tryParse(q);
    final c = (n != null && m != null) ? n.compareTo(m) : p.compareTo(q);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}

/// ComicInfo.xml（漫畫閱讀軟體通用的資訊檔）
String comicInfoXml({required String title, String series = '', String number = '', String writer = '', List<String> tags = const [], String web = '', int pages = 0, String notes = ''}) {
  String esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
  final b = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n<ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\n');
  void f(String k, String v) {
    if (v.isNotEmpty) b.write('  <$k>${esc(v)}</$k>\n');
  }

  f('Title', title);
  f('Series', series);
  f('Number', number);
  f('Writer', writer);
  f('Tags', tags.join(', '));
  f('Web', web);
  if (pages > 0) f('PageCount', '$pages');
  f('Notes', notes);
  b.write('</ComicInfo>\n');
  return b.toString();
}

/// 讀 ComicInfo.xml 裡的欄位
String comicInfoField(String? xml, String field) {
  if (xml == null) return '';
  final m = RegExp('<$field>([\\s\\S]*?)</$field>').firstMatch(xml);
  return (m?.group(1) ?? '').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&amp;', '&').trim();
}
