import 'source.dart';
import 'sources/eh.dart';
import 'sources/jm.dart';
import 'sources/nh.dart';
import 'sources/va.dart';
import 'sources/vb.dart';
import 'sources/vc.dart';
import 'sources/wn.dart';

/// 全部來源（順序 = 畫面上的順序）
final Map<String, Source> sources = {
  'va': VaSource(),
  'vb': VbSource(),
  'vc': VcSource(),
  'nh': NhSource(),
  'jm': JmSource(),
  'wn': WnSource(),
  'eh': EhSource(),
};

Source src(String key) => sources[key]!;

VaSource get va => sources['va'] as VaSource;
NhSource get nh => sources['nh'] as NhSource;
JmSource get jm => sources['jm'] as JmSource;
EhSource get eh => sources['eh'] as EhSource;
