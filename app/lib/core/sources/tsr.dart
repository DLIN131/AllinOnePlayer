/// 網頁裡內嵌的頁面資料（框架把伺服器端讀好的資料寫成一段 JS：$_TSR.router=($R=>$R[0]={…})(…)）。
/// 不執行網站的程式碼，自己解析這種格式：物件、陣列、字串、數字、!0/!1、null，
/// 以及「$R[n]=值」（定義）和「$R[n]」（重複出現時的參照）。電腦版的 tsr.js 是同一套規則。
///
/// 結果：物件 → Map<String, Object?>，陣列 → List<Object?>，數字 → double，其餘照原樣。
class Tsr {
  final String s;
  int i;
  final _refs = <int, Object?>{};
  Tsr._(this.s, this.i);

  static const _mark = r'$_TSR.router=($R=>';
  static final _number = RegExp(r'-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?');
  static final _key = RegExp(r'[A-Za-z_$][\w$]*|\d+');

  Never _fail(String msg) => throw FormatException('頁面資料格式不認得（$msg，位置 $i）');

  void _ws() {
    while (i < s.length && (s.codeUnitAt(i) == 32 || s.codeUnitAt(i) == 10 || s.codeUnitAt(i) == 13 || s.codeUnitAt(i) == 9)) {
      i++;
    }
  }

  bool _eat(String str) {
    _ws();
    if (s.startsWith(str, i)) {
      i += str.length;
      return true;
    }
    return false;
  }

  Object? _value() {
    _ws();
    if (i >= s.length) _fail('資料沒有結束');
    if (s.startsWith(r'$R[', i)) {
      i += 3;
      final end = s.indexOf(']', i);
      final n = int.parse(s.substring(i, end));
      i = end + 1;
      // 「$R[n]=」是定義，不是「==」
      if (i < s.length && s[i] == '=' && (i + 1 >= s.length || s[i + 1] != '=')) {
        i++;
        final v = _value();
        _refs[n] = v;
        return v;
      }
      return _refs[n];
    }
    final c = s[i];
    if (c == '{') return _obj();
    if (c == '[') return _arr();
    if (c == '"' || c == "'") return _str();
    if (_eat('!0')) return true;
    if (_eat('!1')) return false;
    if (_eat('null')) return null;
    if (_eat('void 0')) return null;
    if (_eat('true')) return true;
    if (_eat('false')) return false;
    final m = _number.matchAsPrefix(s, i);
    if (m != null) {
      i = m.end;
      return double.parse(m.group(0)!);
    }
    if (_eat('Infinity')) return double.infinity;
    if (_eat('NaN')) return double.nan;
    _fail('意外的字元 ${s.substring(i, (i + 12).clamp(0, s.length))}');
  }

  String _keyName() {
    _ws();
    final c = s[i];
    if (c == '"' || c == "'") return _str();
    final m = _key.matchAsPrefix(s, i) ?? _fail('物件的鍵');
    i = m.end;
    return m.group(0)!;
  }

  Map<String, Object?> _obj() {
    i++;
    final o = <String, Object?>{};
    if (_eat('}')) return o;
    while (true) {
      final k = _keyName();
      if (!_eat(':')) _fail('缺少冒號');
      o[k] = _value();
      if (_eat(',')) continue;
      if (_eat('}')) return o;
      _fail('物件沒有結束');
    }
  }

  List<Object?> _arr() {
    i++;
    final a = <Object?>[];
    while (true) {
      _ws();
      if (_eat(']')) return a;
      // 空位（[1,,2]）
      if (s[i] == ',') {
        i++;
        a.add(null);
        continue;
      }
      a.add(_value());
      if (_eat(',')) continue;
      if (_eat(']')) return a;
      _fail('陣列沒有結束');
    }
  }

  String _str() {
    final q = s[i++];
    final out = StringBuffer();
    while (true) {
      if (i >= s.length) _fail('字串沒有結束');
      final c = s[i++];
      if (c == q) return out.toString();
      if (c != r'\') {
        out.write(c);
        continue;
      }
      final e = s[i++];
      switch (e) {
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case 'b':
          out.write('\b');
        case 'f':
          out.write('\f');
        case 'v':
          out.write('\v');
        case '0':
          out.write('\u0000');
        case 'x':
          out.writeCharCode(int.parse(s.substring(i, i + 2), radix: 16));
          i += 2;
        case 'u':
          if (s[i] == '{') {
            final end = s.indexOf('}', i);
            out.writeCharCode(int.parse(s.substring(i + 1, end), radix: 16));
            i = end + 1;
          } else {
            out.writeCharCode(int.parse(s.substring(i, i + 4), radix: 16));
            i += 4;
          }
        case '\n':
          break; // 續行
        default:
          out.write(e);
      }
    }
  }

  /// 從頁面 HTML 取出這一頁的資料（最後一個路由的 loader 資料）；找不到回傳 null
  static Map<String, Object?>? pageData(String html) {
    final at = html.indexOf(_mark);
    if (at < 0) return null;
    final router = Tsr._(html, at + _mark.length)._value();
    if (router is! Map) return null;
    final matches = router['matches'];
    if (matches is! List) return {};
    for (final m in matches.reversed) {
      final l = m is Map ? m['l'] : null;
      if (l is Map) return Map<String, Object?>.from(l)..remove('ads');
    }
    return {};
  }
}
