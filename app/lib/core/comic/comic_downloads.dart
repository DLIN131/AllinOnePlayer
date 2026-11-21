import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../fetch_bytes.dart';
import '../model.dart';
import '../native.dart';
import '../registry.dart';
import '../sites.dart';
import '../store.dart';
import 'cbz.dart';
import 'descramble.dart';

/// 一個漫畫下載工作（一本，或一本的某一話）
class ComicJob {
  final String id;
  final Item item;
  final String chapterId;
  final String chapterTitle;
  String status; // queued | running | paused | failed | done
  int done;
  int total;
  String file;
  String error;
  final int time;

  ComicJob(this.id, this.item, {this.chapterId = '', this.chapterTitle = '', this.status = 'queued', this.done = 0, this.total = 0, this.file = '', this.error = '', int? time})
      : time = time ?? DateTime.now().millisecondsSinceEpoch;

  double get progress => status == 'done' ? 1 : (total > 0 ? done / total : 0);

  Map<String, Object?> toJson() => {
        'id': id, 'item': item.toJson(), 'ch': chapterId, 'cht': chapterTitle, 'status': status,
        'done': done, 'total': total, 'file': file, 'error': error, 't': time,
      };

  factory ComicJob.fromJson(Map j) => ComicJob(
        j['id'] as String,
        Item.fromJson(j['item'] as Map),
        chapterId: j['ch'] ?? '',
        chapterTitle: j['cht'] ?? '',
        // App 關掉時沒下載完的當作暫停
        status: (j['status'] == 'done' || j['status'] == 'failed') ? j['status'] as String : 'paused',
        done: (j['done'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        file: j['file'] ?? '',
        error: j['error'] ?? '',
        time: (j['t'] as num?)?.toInt(),
      );
}

/// 漫畫下載：一次一本，每本同時抓 4 張，依頁序寫進 CBZ（含 ComicInfo.xml）。jm 的切條圖在背景還原後再存。
class ComicDownloads extends ChangeNotifier {
  static final ComicDownloads instance = ComicDownloads._();
  ComicDownloads._();

  final jobs = <ComicJob>[];
  bool _running = false;
  ComicJob? _current;
  bool _cancel = false;

  static String get dir => '${Native.info.externalDir}/comics';

  void load() {
    final raw = Store.instance.raw('comicJobs');
    if (raw is List) {
      jobs
        ..clear()
        ..addAll([for (final j in raw) if (j is Map) ComicJob.fromJson(j)]);
    }
  }

  void _save() {
    Store.instance.setRaw('comicJobs', [for (final j in jobs) j.toJson()]);
    notifyListeners();
  }

  ComicJob? find(String id) => jobs.where((j) => j.id == id).firstOrNull;

  void add(Item item, {String chapterId = '', String chapterTitle = ''}) {
    final id = chapterId.isEmpty ? item.key : '${item.key}_$chapterId';
    jobs.removeWhere((j) => j.id == id);
    jobs.insert(0, ComicJob(id, item, chapterId: chapterId, chapterTitle: chapterTitle));
    _save();
    _kick();
  }

  void pause(String id) {
    final j = find(id);
    if (j == null) return;
    if (_current?.id == id) _cancel = true;
    if (j.status == 'running' || j.status == 'queued') j.status = 'paused';
    _save();
  }

  void resume(String id) {
    final j = find(id);
    if (j == null || j.status == 'done') return;
    j.status = 'queued';
    j.error = '';
    _save();
    _kick();
  }

  /// 只刪工作紀錄；deleteFile = true 連檔案一起刪
  Future<void> remove(String id, {bool deleteFile = false}) async {
    final j = find(id);
    if (j == null) return;
    if (_current?.id == id) _cancel = true;
    jobs.remove(j);
    _save();
    if (deleteFile && j.file.isNotEmpty) {
      try {
        await File(j.file).delete();
      } catch (_) {}
    }
  }

  Future<void> _kick() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final next = jobs.lastWhere((j) => j.status == 'queued', orElse: () => ComicJob('', const Item(src: '', id: '', title: '', cover: '')));
        if (next.id.isEmpty) break;
        _current = next;
        _cancel = false;
        await _run(next);
        _current = null;
      }
    } finally {
      _running = false;
    }
  }

  static String fileName(Item item, String chapterTitle) {
    final s = src(item.src);
    var title = item.title.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (title.length > 80) title = title.substring(0, 80).trim();
    final ch = chapterTitle.isEmpty ? '' : ' - ${chapterTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ').trim()}';
    return '[${Sites.label(item.src)}] $title$ch (${s.idTag(item.id)}).cbz';
  }

  Future<void> _run(ComicJob job) async {
    job.status = 'running';
    job.error = '';
    job.done = 0;
    _save();
    final s = src(job.item.src);
    CbzWriter? w;
    try {
      final d = await s.detail(job.item);
      final pages = await s.read(d, job.chapterId.isEmpty ? null : job.chapterId);
      job.total = pages.length;
      job.file = '$dir/${fileName(d.item, job.chapterTitle)}';
      _save();
      w = await CbzWriter.create('${job.file}.part');
      final headers = s.imageHeaders;
      for (var i = 0; i < pages.length; i += 4) {
        if (_cancel) throw const _Cancelled();
        final batch = [for (var k = i; k < i + 4 && k < pages.length; k++) k];
        final data = await Future.wait(batch.map((k) => _page(pages[k], headers)));
        for (var n = 0; n < batch.length; n++) {
          final (bytes, ext) = data[n];
          await w.add('${(batch[n] + 1).toString().padLeft(4, '0')}.$ext', bytes);
        }
        job.done = batch.last + 1;
        notifyListeners();
      }
      final tags = [for (final t in d.tags) t.title];
      final writers = [for (final t in d.tags) if (t.title.startsWith('作者')) t.title.split('：').last];
      await w.add(
        'ComicInfo.xml',
        Uint8List.fromList(utf8.encode(comicInfoXml(
          title: d.title + (job.chapterTitle.isEmpty ? '' : ' - ${job.chapterTitle}'),
          series: job.chapterTitle.isEmpty ? '' : d.title,
          number: job.chapterTitle,
          writer: writers.join(', '),
          tags: tags,
          web: d.url,
          pages: pages.length,
          notes: '${Sites.label(job.item.src)} ${s.idTag(job.item.id)}',
        ))),
      );
      await w.close();
      w = null;
      final part = File('${job.file}.part');
      final out = File(job.file);
      if (await out.exists()) await out.delete();
      await part.rename(job.file);
      job.status = 'done';
    } on _Cancelled {
      if (job.status == 'running') job.status = 'paused';
    } catch (e) {
      job.status = 'failed';
      job.error = e is NetError ? e.message : '$e';
    } finally {
      if (w != null) {
        try {
          await w.close();
        } catch (_) {}
      }
      if (jobs.contains(job)) _save();
    }
  }

  Future<(Uint8List, String)> _page(ComicPage p, Map<String, String> headers) async {
    var url = p.url;
    if (p.resolve != null) url = await p.resolve!(false);
    Uint8List bytes;
    try {
      bytes = await fetchBytes(url, headers: headers);
    } catch (e) {
      // eh：換一台圖片伺服器再試
      if (p.resolve == null) rethrow;
      bytes = await fetchBytes(await p.resolve!(true), headers: headers);
    }
    if (p.segs > 0) return (await compute(descrambleJpeg, (bytes, p.segs)), 'jpg');
    return (bytes, _ext(url, bytes));
  }

  static String _ext(String url, Uint8List b) {
    if (b.length > 4 && b[0] == 0x89 && b[1] == 0x50) return 'png';
    if (b.length > 4 && b[0] == 0x47 && b[1] == 0x49) return 'gif';
    if (b.length > 12 && b[8] == 0x57 && b[9] == 0x45) return 'webp';
    final m = RegExp(r'\.(jpe?g|png|webp|gif)(?:\?|$)', caseSensitive: false).firstMatch(url);
    return m?.group(1)?.toLowerCase() ?? 'jpg';
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
