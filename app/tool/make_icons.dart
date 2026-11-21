// 產生舊版 Android（8.0 以前）用的圖示 PNG：黑底、紅色圓角方塊、白色播放三角形
import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  const sizes = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};
  sizes.forEach((dir, n) {
    final im = img.Image(width: n, height: n, numChannels: 4);
    img.fill(im, color: img.ColorRgba8(0, 0, 0, 0));
    final r = (n * 0.18).round();
    img.fillRect(im, x1: 0, y1: 0, x2: n - 1, y2: n - 1, color: img.ColorRgba8(0xE1, 0x1D, 0x48, 255), radius: r);
    final cx = n / 2, cy = n / 2, s = n * 0.22;
    img.fillPolygon(im, vertices: [img.Point(cx - s * 0.75, cy - s), img.Point(cx - s * 0.75, cy + s), img.Point(cx + s, cy)], color: img.ColorRgba8(255, 255, 255, 255));
    File('android/app/src/main/res/mipmap-$dir/ic_launcher.png').writeAsBytesSync(img.encodePng(im));
  });
}
