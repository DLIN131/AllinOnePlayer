import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// jm 的圖被橫切成 num 條上下倒置。回傳每一條（來源 y, 目標 y, 高度）
List<(int, int, int)> strips(int h, int num) {
  final over = h % num;
  final base = h ~/ num;
  return [
    for (var i = 0; i < num; i++)
      (
        h - base * (i + 1) - over,
        base * i + (i == 0 ? 0 : over),
        base + (i == 0 ? over : 0),
      ),
  ];
}

/// 閱讀用：直接在畫布上依切條畫回去（不重新編碼）
ui.Picture descramblePicture(ui.Image src, int num) {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final w = src.width.toDouble();
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
  for (final (ySrc, yDst, h) in strips(src.height, num)) {
    c.drawImageRect(src, ui.Rect.fromLTWH(0, ySrc.toDouble(), w, h.toDouble()), ui.Rect.fromLTWH(0, yDst.toDouble(), w, h.toDouble()), paint);
  }
  return rec.endRecording();
}

Future<ui.Image> descrambleImage(ui.Image src, int num) => descramblePicture(src, num).toImage(src.width, src.height);

/// 下載用（在背景 isolate 跑）：解碼 → 拼回 → 存成 JPEG（品質 92）
Uint8List descrambleJpeg((Uint8List, int) args) {
  final (data, num) = args;
  final src = img.decodeImage(data);
  if (src == null) throw Exception('圖片解碼失敗');
  final out = img.Image(width: src.width, height: src.height, numChannels: 3);
  for (final (ySrc, yDst, h) in strips(src.height, num)) {
    img.compositeImage(out, src, dstX: 0, dstY: yDst, srcX: 0, srcY: ySrc, srcW: src.width, srcH: h, dstW: src.width, dstH: h);
  }
  return img.encodeJpg(out, quality: 92);
}
