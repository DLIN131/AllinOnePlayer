import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'store.dart';

/// 開啟密碼：4 位數 PIN + 8 位數救援碼，兩個都只存 PBKDF2 雜湊（加鹽、一萬次）。
/// 連錯 5 次後鎖 30 秒，之後每次加倍，最多 15 分鐘（重開 App 也算）。App 在背景超過 60 秒回來要重新輸入。
class PinLock {
  static final _store = Store.instance;
  static const _iterations = 10000;
  static const freeTries = 5;

  static Map<String, dynamic> get _d => Map<String, dynamic>.from((_store.raw('pin') as Map?) ?? const {});
  static void _set(Map<String, dynamic> d) => _store.setRaw('pin', d);

  static bool get enabled => _d['pin'] != null;

  /// 第一次開 App 問過要不要設密碼了沒
  static bool get asked => _d['asked'] == true || enabled;
  static void markAsked() => _set(_d..['asked'] = true);

  static String _hash(String secret, String salt) {
    final key = _pbkdf2(utf8.encode(secret), base64.decode(salt), _iterations, 32);
    return base64.encode(key);
  }

  static Uint8List _pbkdf2(List<int> password, List<int> salt, int iterations, int length) {
    final hmac = Hmac(sha256, password);
    final out = BytesBuilder();
    var block = 1;
    while (out.length < length) {
      final s = Uint8List(salt.length + 4)
        ..setAll(0, salt)
        ..buffer.asByteData().setUint32(salt.length, block);
      var u = hmac.convert(s).bytes;
      final t = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = hmac.convert(u).bytes;
        for (var k = 0; k < t.length; k++) {
          t[k] ^= u[k];
        }
      }
      out.add(t);
      block++;
    }
    return out.toBytes().sublist(0, length);
  }

  static String _salt() {
    final r = Random.secure();
    return base64.encode(List.generate(16, (_) => r.nextInt(256)));
  }

  static String _code() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(10)).join();
  }

  /// 設定（或更換）PIN，回傳新的救援碼（要讓使用者抄下來）
  static String setPin(String pin) {
    final code = _code();
    final salt = _salt(), codeSalt = _salt();
    _set({'pin': _hash(pin, salt), 'salt': salt, 'code': _hash(code, codeSalt), 'codeSalt': codeSalt, 'asked': true});
    return code;
  }

  static String newRecoveryCode() {
    final code = _code();
    final salt = _salt();
    _set(_d
      ..['code'] = _hash(code, salt)
      ..['codeSalt'] = salt);
    return code;
  }

  static void disable() => _set({'asked': true});

  /// 剩幾秒才能再試（0 = 現在可以）
  static int get lockedSeconds {
    final until = (_d['lockUntil'] as num?)?.toInt() ?? 0;
    final left = until - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? (left / 1000).ceil() : 0;
  }

  static int get failures => (_d['fails'] as num?)?.toInt() ?? 0;

  static bool check(String pin) => _verify(pin, 'pin', 'salt');

  /// 用救援碼解鎖：成功後換一組新的救援碼（舊的作廢），回傳新碼
  static String? recover(String code) {
    if (!_verify(code, 'code', 'codeSalt')) return null;
    return newRecoveryCode();
  }

  static bool _verify(String secret, String field, String saltField) {
    if (lockedSeconds > 0) return false;
    final d = _d;
    final ok = d[field] != null && _hash(secret, d[saltField] as String) == d[field];
    if (ok) {
      d['fails'] = 0;
      d.remove('lockUntil');
    } else {
      final fails = failures + 1;
      d['fails'] = fails;
      if (fails >= freeTries) {
        final secs = min(30 * pow(2, fails - freeTries).toInt(), 15 * 60);
        d['lockUntil'] = DateTime.now().millisecondsSinceEpoch + secs * 1000;
      }
    }
    _set(d);
    return ok;
  }
}
