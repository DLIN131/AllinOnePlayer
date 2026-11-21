// 電腦版圖示（icon.png 256、icon.ico 多尺寸）：紅色圓角方塊、白色播放三角形
import 'dart:io';
import 'package:image/image.dart' as img;

img.Image draw(int n) {
  final im = img.Image(width: n, height: n, numChannels: 4);
  img.fill(im, color: img.ColorRgba8(0, 0, 0, 0));
  img.fillRect(im, x1: 0, y1: 0, x2: n - 1, y2: n - 1, color: img.ColorRgba8(0xE1, 0x1D, 0x48, 255), radius: (n * 0.2).round());
  final c = n / 2, s = n * 0.22;
  img.fillPolygon(im, vertices: [img.Point(c - s * 0.75, c - s), img.Point(c - s * 0.75, c + s), img.Point(c + s, c)], color: img.ColorRgba8(255, 255, 255, 255));
  return im;
}

void main() {
  const out = '../desktop/src';
  File('$out/icon.png').writeAsBytesSync(img.encodePng(draw(256)));
  File('$out/icon.ico').writeAsBytesSync(img.IcoEncoder().encodeImages([for (final n in [16, 24, 32, 48, 64, 128, 256]) draw(n)]));
}
