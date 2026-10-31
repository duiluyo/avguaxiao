import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:smb_connect/smb_connect.dart' as smb;

/// 每次修改代码都要同步修改这里和 pubspec.yaml 里的 version
const appVersion = '1.7.0';

void main() => runApp(const ScraperApp());

final themeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

ThemeMode themeFromString(String s) => s == 'light'
    ? ThemeMode.light
    : s == 'dark'
        ? ThemeMode.dark
        : ThemeMode.system;

String themeToString(ThemeMode m) => m == ThemeMode.light
    ? 'light'
    : m == ThemeMode.dark
        ? 'dark'
        : 'system';

class ScraperApp extends StatelessWidget {
  const ScraperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) => MaterialApp(
        title: '影片刮削器',
        themeMode: mode,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}

// ═══════════════════════ 配置 ═══════════════════════

/// 设置与撤销记录的保存位置：安卓在手机根目录，电脑在 %APPDATA%\影片刮削器
final String _dataDir = Platform.isAndroid
    ? '/storage/emulated/0/刮削器'
    : p.join(
        Platform.environment['APPDATA'] ??
            Platform.environment['HOME'] ??
            Directory.systemTemp.path,
        '影片刮削器');
final String _cfgPath = p.join(_dataDir, 'config.json');

class Cfg {
  String javbusUrl = 'https://www.javbus.com';
  String javdbUrl = 'https://javdb.com';
  String proxy = '';
  bool useJavbus = true;
  bool useJavdb = true;
  bool useDmm = true;
  bool skipExisting = true;
  bool downloadCover = true;
  bool organize = true;
  String folderMode = 'num';
  bool downloadSub = false;
  String subUrl = 'https://www.subtitlecat.com';
  String themeMode = 'system';
  bool keepAwake = true;
  String source = 'local'; // local=本机 smb=网络共享
  String smbHost = '';
  String smbUser = '';
  String smbPass = '';
  String smbDomain = '';
  String smbPath = '';
  bool downloadStills = false;
  int stillsMax = 10;
  bool translate = false;
  String trLang = 'zh-CN';
  String folderTpl = '{番号}'; // 文件夹命名模板
  String organizeBase = 'here'; // here=视频所在文件夹  root=所选根文件夹
  bool autoLibrary = true; // 电脑版：刮削后自动加入影视库

  Map<String, dynamic> toJson() => {
        'javbusUrl': javbusUrl,
        'javdbUrl': javdbUrl,
        'proxy': proxy,
        'useJavbus': useJavbus,
        'useJavdb': useJavdb,
        'useDmm': useDmm,
        'skipExisting': skipExisting,
        'downloadCover': downloadCover,
        'organize': organize,
        'folderMode': folderMode,
        'downloadSub': downloadSub,
        'subUrl': subUrl,
        'themeMode': themeMode,
        'keepAwake': keepAwake,
        'source': source,
        'smbHost': smbHost,
        'smbUser': smbUser,
        'smbPass': smbPass,
        'smbDomain': smbDomain,
        'smbPath': smbPath,
        'downloadStills': downloadStills,
        'stillsMax': stillsMax,
        'translate': translate,
        'trLang': trLang,
        'folderTpl': folderTpl,
        'organizeBase': organizeBase,
        'autoLibrary': autoLibrary,
      };

  void load(Map<String, dynamic> j) {
    javbusUrl = (j['javbusUrl'] ?? javbusUrl) as String;
    javdbUrl = (j['javdbUrl'] ?? javdbUrl) as String;
    proxy = (j['proxy'] ?? proxy) as String;
    useJavbus = (j['useJavbus'] ?? useJavbus) as bool;
    useJavdb = (j['useJavdb'] ?? useJavdb) as bool;
    useDmm = (j['useDmm'] ?? useDmm) as bool;
    skipExisting = (j['skipExisting'] ?? skipExisting) as bool;
    downloadCover = (j['downloadCover'] ?? downloadCover) as bool;
    organize = (j['organize'] ?? organize) as bool;
    folderMode = (j['folderMode'] ?? folderMode) as String;
    downloadSub = (j['downloadSub'] ?? downloadSub) as bool;
    subUrl = (j['subUrl'] ?? subUrl) as String;
    themeMode = (j['themeMode'] ?? themeMode) as String;
    keepAwake = (j['keepAwake'] ?? keepAwake) as bool;
    source = (j['source'] ?? source) as String;
    smbHost = (j['smbHost'] ?? smbHost) as String;
    smbUser = (j['smbUser'] ?? smbUser) as String;
    smbPass = (j['smbPass'] ?? smbPass) as String;
    smbDomain = (j['smbDomain'] ?? smbDomain) as String;
    smbPath = (j['smbPath'] ?? smbPath) as String;
    downloadStills = (j['downloadStills'] ?? downloadStills) as bool;
    stillsMax = (j['stillsMax'] ?? stillsMax) as int;
    translate = (j['translate'] ?? translate) as bool;
    trLang = (j['trLang'] ?? trLang) as String;
    organizeBase = (j['organizeBase'] ?? organizeBase) as String;
    if (j['folderTpl'] is String) {
      folderTpl = j['folderTpl'] as String;
    } else {
      // 兼容旧版本的三种固定命名方式
      final fm = j['folderMode'];
      if (fm == 'numTitle') folderTpl = '{番号} {标题}';
      if (fm == 'orig') folderTpl = '{原文件名}';
    }
    autoLibrary = (j['autoLibrary'] ?? autoLibrary) as bool;
  }
}

// ═══════════════════════ 网络 ═══════════════════════

const _ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

class Net {
  late final http.Client _client;
  final Duration timeout;
  final int tries;

  Net(String proxy,
      {this.timeout = const Duration(seconds: 25), this.tries = 2}) {
    final hc = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final px = proxy
        .trim()
        .replaceFirst(RegExp(r'^[a-zA-Z]+://'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (px.isNotEmpty) {
      hc.findProxy = (uri) => 'PROXY $px';
    }
    _client = IOClient(hc);
  }

  void close() => _client.close();

  Future<http.Response> get(String url, {Map<String, String>? extra}) async {
    final uri = Uri.parse(url);
    final headers = <String, String>{
      'User-Agent': _ua,
      'Accept-Language': 'zh-CN,zh;q=0.9,ja;q=0.8,en;q=0.7',
      'Referer': '${uri.scheme}://${uri.host}/',
      if (extra != null) ...extra,
    };
    Object? last;
    for (var i = 0; i < tries; i++) {
      try {
        return await _client
            .get(uri, headers: headers)
            .timeout(timeout);
      } catch (e) {
        last = e;
      }
    }
    throw last!;
  }
}

String decodeBody(http.Response r) =>
    utf8.decode(r.bodyBytes, allowMalformed: true);

bool looksBlocked(String body) =>
    body.contains('Just a moment') ||
    body.contains('cf-browser-verification') ||
    body.contains('Attention Required');

String trimSlash(String s) => s.trim().replaceAll(RegExp(r'/+$'), '');

String errText(Object e) {
  if (e is TimeoutException) return '超时（网络慢，或需要代理）';
  if (e is SocketException || e is http.ClientException) {
    return '连接失败（可能需要代理）';
  }
  final s = e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

// ═══════════════════════ 番号识别 ═══════════════════════

const _videoExts = {
  '.mp4', '.mkv', '.avi', '.wmv', '.mov', '.ts', '.m2ts',
  '.flv', '.rmvb', '.mpg', '.webm',
};

const _bannedPrefix = {
  'AVC', 'HEVC', 'AAC', 'FHD', 'UHD', 'WEB', 'BLURAY', 'HDTV', 'DVD',
  'CD', 'PART', 'DISC', 'HD', 'SD', 'DDP', 'DTS', 'EAC', 'AC', 'MP',
};

final _domainRe = RegExp(
    r'[A-Za-z0-9\-]+\.(?:com|net|org|cc|me|tv|xyz|top|vip|info|io|co|la|ru|app|club|site|fun)',
    caseSensitive: false);

/// 文件名后面跟着 -C / -U / -UC 之类的标记 → 中文字幕 / 无码
List<String> _flagTags(String tail) {
  final m = RegExp(r'^[-_ .]*(UC|C|U|UNCENSORED|LEAK|LEAKED)(?![A-Za-z])',
          caseSensitive: false)
      .firstMatch(tail);
  if (m == null) return [];
  final f = m.group(1)!.toUpperCase();
  return [
    if (f == 'C' || f == 'UC') '中文字幕',
    if (f == 'U' || f == 'UC' || f == 'UNCENSORED' || f.startsWith('LEAK'))
      '无码',
  ];
}

/// 返回 (番号, 标记)。支持：
///  - 普通番号 SSIS-123 / ssis00123 / HEYZO-1234
///  - FC2：FC2-PPV-1234567
///  - 日期型（一本道、加勒比等）：010123_001 / 010123-001
(String, List<String>)? _parseCode(String filename) {
  var base = p.basenameWithoutExtension(filename);
  base = base.replaceAll(_domainRe, ' '); // 去掉 xxx.com@ 之类的网址前缀

  final fc2 = RegExp(r'(?<![A-Za-z0-9])FC2[-_ ]?(?:PPV)?[-_ ]?(\d{5,8})(?!\d)',
          caseSensitive: false)
      .firstMatch(base);
  if (fc2 != null) {
    return ('FC2-PPV-${fc2.group(1)}', _flagTags(base.substring(fc2.end)));
  }

  final dated =
      RegExp(r'(?<!\d)(\d{6})([-_])(\d{2,4})(?!\d)').firstMatch(base);
  if (dated != null) {
    return (
      '${dated.group(1)}${dated.group(2)}${dated.group(3)}',
      _flagTags(base.substring(dated.end)),
    );
  }

  final re = RegExp(r'(?<![A-Za-z0-9])([A-Za-z]{2,6})[-_ ]?(\d{2,5})(?!\d)');
  for (final m in re.allMatches(base)) {
    final letters = m.group(1)!.toUpperCase();
    if (_bannedPrefix.contains(letters)) continue;
    final n = int.parse(m.group(2)!);
    return (
      '$letters-${n.toString().padLeft(3, '0')}',
      _flagTags(base.substring(m.end)),
    );
  }
  return null;
}

/// "[xxx] ssis00123 1080p.mp4" -> "SSIS-123"
String? extractCode(String filename) => _parseCode(filename)?.$1;

List<String> codeTags(String filename) => _parseCode(filename)?.$2 ?? [];

// ═══════════════════════ 数据模型 ═══════════════════════

/// 单个来源抓到的资料
class Partial {
  final String source;
  String url = '';
  String title = '';
  String date = '';
  String studio = '';
  String director = '';
  String series = '';
  int runtime = 0;
  List<String> genres = [];
  List<String> actors = [];
  List<String> covers = [];
  List<String> stills = [];
  Partial(this.source);
  bool get hasMeta => title.isNotEmpty;
}

/// 合并后的最终资料
class Movie {
  final String num;
  String title = '';
  String date = '';
  String studio = '';
  String director = '';
  String series = '';
  int runtime = 0;
  List<String> genres = [];
  List<String> actors = [];
  List<String> covers = [];
  List<String> sources = [];
  List<String> urls = [];
  List<String> stills = [];
  String titleZh = '';
  bool translated = false;
  Movie(this.num);
  String get displayTitle => titleZh.isNotEmpty ? titleZh : title;
}

void _union(List<String> to, List<String> from) {
  for (final x in from) {
    if (x.isNotEmpty && !to.contains(x)) to.add(x);
  }
}

/// 按来源优先级合并：单值字段取第一个非空；列表字段取并集
Movie mergeAll(String num, List<Partial> parts) {
  final m = Movie(num);
  for (final part in parts) {
    if (m.title.isEmpty) m.title = part.title;
    if (m.date.isEmpty) m.date = part.date;
    if (m.studio.isEmpty) m.studio = part.studio;
    if (m.director.isEmpty) m.director = part.director;
    if (m.series.isEmpty) m.series = part.series;
    if (m.runtime == 0) m.runtime = part.runtime;
    _union(m.genres, part.genres);
    _union(m.actors, part.actors);
    _union(m.covers, part.covers);
    if (m.stills.isEmpty && part.stills.isNotEmpty) m.stills = List.of(part.stills);
    if (part.hasMeta) m.sources.add(part.source);
    if (part.url.isNotEmpty) m.urls.add(part.url);
  }
  return m;
}

// ═══════════════════════ 刮削源 ═══════════════════════

List<String> _texts(dom.Element? e, String selector) {
  if (e == null) return [];
  return e
      .querySelectorAll(selector)
      .map((x) => x.text.trim())
      .where((s) => s.isNotEmpty)
      .toList();
}

/// 来源 1：JavBus（同结构的镜像站也可以填进来）
Future<Partial?> scrapeJavbus(Net net, String baseUrl, String num) async {
  final base = trimSlash(baseUrl);
  final url = '$base/$num';
  final r = await net
      .get(url, extra: {'Cookie': 'existmag=all; age=verified; dv=1'});
  if (r.statusCode == 404) return null;
  if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
  final body = decodeBody(r);
  if (looksBlocked(body)) throw '被网站拦截（Cloudflare）';
  final doc = html_parser.parse(body);
  final h3 = doc.querySelector('div.container h3');
  if (h3 == null) throw '页面结构不符（可能被拦截，或需要代理）';

  final out = Partial('JavBus')..url = url;
  var title = h3.text.trim();
  if (title.toUpperCase().startsWith(num)) {
    title = title.substring(num.length).trim();
  }
  out.title = title;

  final big = doc.querySelector('a.bigImage');
  final page = Uri.parse(url);
  for (final c in [
    big?.attributes['href'],
    big?.querySelector('img')?.attributes['src'],
  ]) {
    if (c != null && c.isNotEmpty) {
      final full = page.resolve(c).toString();
      if (!out.covers.contains(full)) out.covers.add(full);
    }
  }

  final box = doc.querySelector('div.info');
  if (box != null) {
    final text = box.text;
    out.date = RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(text)?.group(0) ?? '';
    final rt = RegExp(r'(\d+)\s*(?:分鐘|分钟|min)').firstMatch(text);
    out.runtime = int.tryParse(rt?.group(1) ?? '') ?? 0;
    String first(String key) =>
        box.querySelector('a[href*="/$key/"]')?.text.trim() ?? '';
    out.studio = first('studio');
    out.director = first('director');
    out.series = first('series');
    out.genres = _texts(box, 'a[href*="/genre/"]');
  }
  out.actors = doc
      .querySelectorAll('div.star-name a')
      .map((e) => (e.attributes['title'] ?? e.text).trim())
      .where((s) => s.isNotEmpty)
      .toList();
  out.stills = doc
      .querySelectorAll('a.sample-box')
      .map((e) => e.attributes['href'] ?? '')
      .where((s) => s.isNotEmpty)
      .map((s) => page.resolve(s).toString())
      .toList();
  return out;
}

/// 来源 2：JavDB（有时会被 Cloudflare 拦截，失败会在日志里写明）
Future<Partial?> scrapeJavdb(Net net, String baseUrl, String num) async {
  final base = trimSlash(baseUrl);
  const ck = {'Cookie': 'over18=1; locale=zh'};

  final sr = await net.get(
      '$base/search?q=${Uri.encodeQueryComponent(num)}&f=all',
      extra: ck);
  if (sr.statusCode != 200) throw '搜索页 HTTP ${sr.statusCode}';
  final sbody = decodeBody(sr);
  if (looksBlocked(sbody)) throw '被网站拦截（Cloudflare）';
  final sdoc = html_parser.parse(sbody);

  String? href;
  for (final a in sdoc.querySelectorAll('a.box')) {
    final t = a.querySelector('.video-title strong')?.text.trim() ?? '';
    if (t.toUpperCase() == num) {
      href = a.attributes['href'];
      break;
    }
  }
  if (href == null) return null;

  final durl = Uri.parse('$base/').resolve(href).toString();
  final dr = await net.get(durl, extra: ck);
  if (dr.statusCode != 200) throw '详情页 HTTP ${dr.statusCode}';
  final dbody = decodeBody(dr);
  if (looksBlocked(dbody)) throw '被网站拦截（Cloudflare）';
  final doc = html_parser.parse(dbody);

  final out = Partial('JavDB')..url = durl;
  out.title =
      doc.querySelector('h2.title strong.current-title')?.text.trim() ?? '';
  if (out.title.isEmpty) throw '详情页结构不符';

  final coverSrc = doc.querySelector('img.video-cover')?.attributes['src'] ??
      doc.querySelector('.column-video-cover img')?.attributes['src'] ??
      '';
  if (coverSrc.isNotEmpty) {
    out.covers.add(Uri.parse(durl).resolve(coverSrc).toString());
  }

  for (final blk in doc.querySelectorAll('.panel-block')) {
    final label = blk.querySelector('strong')?.text ?? '';
    final value = blk.querySelector('.value');
    if (value == null) continue;
    final vt = value.text.trim();
    final links = _texts(value, 'a');
    if (label.contains('日期')) {
      out.date = RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(vt)?.group(0) ?? '';
    } else if (label.contains('時長') || label.contains('时长')) {
      out.runtime = int.tryParse(RegExp(r'\d+').firstMatch(vt)?.group(0) ?? '') ?? 0;
    } else if (label.contains('導演') || label.contains('导演')) {
      out.director = links.isNotEmpty ? links.first : vt;
    } else if (label.contains('片商')) {
      out.studio = links.isNotEmpty ? links.first : vt;
    } else if (label.contains('系列')) {
      out.series = links.isNotEmpty ? links.first : vt;
    } else if (label.contains('類別') || label.contains('类别')) {
      out.genres = links;
    } else if (label.contains('演員') || label.contains('演员')) {
      out.actors = links;
    }
  }
  out.stills = doc
      .querySelectorAll('.preview-images a.tile-item')
      .map((e) => e.attributes['href'] ?? '')
      .where((s) =>
          RegExp(r'\.(jpe?g|png|webp)(\?|$)', caseSensitive: false).hasMatch(s))
      .map((s) => Uri.parse(durl).resolve(s).toString())
      .toList();
  return out;
}

/// 来源 3：DMM 官方图床，按番号猜封面地址（只提供封面）
List<String> dmmCovers(String num) {
  final m = RegExp(r'^([A-Z]+)-(\d+)$').firstMatch(num);
  if (m == null) return [];
  final label = m.group(1)!.toLowerCase();
  final digits = m.group(2)!.padLeft(5, '0');
  final cid = '$label$digits';
  return [
    'https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/$cid/${cid}pl.jpg',
    'https://pics.dmm.co.jp/digital/video/$cid/${cid}pl.jpg',
    'https://pics.dmm.co.jp/mono/movie/adult/$cid/${cid}pl.jpg',
  ];
}

// ═══════════════════════ 封面 ═══════════════════════

bool _isImage(Uint8List b) {
  if (b.length < 4) return false;
  final jpg = b[0] == 0xFF && b[1] == 0xD8;
  final png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
  final webp = b.length > 12 &&
      b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;
  return jpg || png || webp;
}

String _short(String u) => u.length > 70 ? '${u.substring(0, 70)}…' : u;

/// 依次尝试每个候选地址，返回第一张下载成功的图片
Future<(Uint8List, String)?> fetchCover(
    Net net, List<String> urls, void Function(String) log) async {
  final fails = <String>[];
  for (final raw in urls) {
    final u = raw.replaceFirst(RegExp(r'^http://'), 'https://');
    try {
      final r = await net.get(u);
      final b = r.bodyBytes;
      if (r.statusCode == 200 && b.length > 5000 && _isImage(b)) {
        return (b, u);
      }
      fails.add('HTTP ${r.statusCode}（${b.length}字节）${_short(u)}');
    } catch (e) {
      fails.add('${errText(e)} ${_short(u)}');
    }
  }
  for (final f in fails.take(5)) {
    log('   封面失败：$f');
  }
  return null;
}

/// 横版封面裁出右半边做竖版海报（在后台线程执行）
Uint8List? makePoster(Uint8List bytes) {
  final im = img.decodeImage(bytes);
  if (im == null) return null;
  if (im.width > im.height * 1.2) {
    final x = (im.width * 0.4733).round();
    final c = img.copyCrop(im,
        x: x, y: 0, width: im.width - x, height: im.height);
    return Uint8List.fromList(img.encodeJpg(c, quality: 92));
  }
  return null;
}

// ═══════════════════════ 整理文件夹 ═══════════════════════

const _sidecarExts = {
  '.srt', '.ass', '.ssa', '.vtt', '.sub', '.idx',
  '.nfo', '.jpg', '.jpeg', '.png',
};

/// 去掉文件名里不能用的字符，并限制长度
String safeName(String s, {int max = 80}) {
  var t = s
      .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.length > max) t = t.substring(0, max).trim();
  t = t.replaceAll(RegExp(r'[. ]+$'), '');
  return t;
}

/// 按模板生成文件夹名（可以是多层）。用 / 分层。
/// 可用变量：{番号} {标题} {原标题} {演员} {年份} {日期} {厂商} {系列} {导演} {原文件名}
/// 演员超过 3 位归入「多人作品」，没有演员信息归入「未知演员」
List<String> folderPartsFor(Movie m, String template, String origStem) {
  final tpl = template.trim().isEmpty ? '{番号}' : template.trim();
  final actor = m.actors.isEmpty
      ? '未知演员'
      : (m.actors.length > 3 ? '多人作品' : m.actors.first);
  final year = m.date.length >= 4 ? m.date.substring(0, 4) : '';
  final vars = <String, String>{
    '番号': m.num,
    'num': m.num,
    '标题': m.displayTitle,
    'title': m.displayTitle,
    '原标题': m.title,
    '演员': actor,
    'actor': actor,
    '年份': year,
    'year': year,
    '日期': m.date,
    'date': m.date,
    '厂商': m.studio,
    'studio': m.studio,
    '系列': m.series,
    'series': m.series,
    '导演': m.director,
    '原文件名': origStem,
  };
  final parts = <String>[];
  for (final seg in tpl.split(RegExp(r'[/\\]'))) {
    final filled = seg.replaceAllMapped(
        RegExp(r'\{([^{}]+)\}'), (mt) => vars[mt.group(1)!.trim()] ?? '');
    final clean = safeName(filled);
    if (clean.isNotEmpty) parts.add(clean);
  }
  return parts.isEmpty ? [safeName(m.num)] : parts;
}

/// 目录 dir 的末尾几层是否正好等于 parts（说明已经在对应的文件夹里了）
bool _tailMatches(String dir, List<String> parts) {
  final segs = p.split(dir);
  if (segs.length < parts.length) return false;
  final tail = segs.sublist(segs.length - parts.length);
  for (var i = 0; i < parts.length; i++) {
    if (tail[i] != parts[i]) return false;
  }
  return true;
}

Future<File> moveFile(File f, String newPath) async {
  if (p.equals(f.path, newPath)) return f;
  if (File(newPath).existsSync()) {
    throw '目标已存在同名文件：${p.basename(newPath)}';
  }
  try {
    return await f.rename(newPath);
  } catch (_) {
    // 跨存储卡时 rename 会失败，改为复制后删除
    final c = await f.copy(newPath);
    await f.delete();
    return c;
  }
}

/// 把视频和它的同名附属文件（字幕、旧 NFO、海报等）移进 destDir，
/// 返回视频的新路径。moves / newDirs 用来记录操作，供「撤销」使用
Future<String> organizeInto(Fs fs, String video, String destDir,
    {List? moves, List? newDirs}) async {
  final srcDir = p.dirname(video);
  if (p.equals(srcDir, destDir)) return video;
  if (!await fs.exists(destDir)) {
    final missing = <String>[];
    var cur = destDir;
    while (!await fs.exists(cur)) {
      missing.add(cur);
      final up = p.dirname(cur);
      if (up == cur) break;
      cur = up;
    }
    await fs.mkdirs(destDir);
    for (final d in missing.reversed) {
      newDirs?.add(d);
    }
  }

  final stem = p.basenameWithoutExtension(video);
  final entries = await fs.list(srcDir);

  final newVideo = p.join(destDir, p.basename(video));
  if (await fs.exists(newVideo)) {
    throw '目标已存在同名文件：${p.basename(newVideo)}';
  }
  await fs.move(video, newVideo);
  moves?.add([video, newVideo]);

  for (final e in entries) {
    if (e.isDir || p.equals(e.path, video)) continue;
    final name = e.name;
    final isSide = name.startsWith('$stem.') ||
        name == '$stem-poster.jpg' ||
        name == '$stem-fanart.jpg';
    if (!isSide) continue;
    if (!_sidecarExts.contains(p.extension(name).toLowerCase())) continue;
    final target = p.join(destDir, name);
    if (await fs.exists(target)) continue;
    try {
      await fs.move(e.path, target);
      moves?.add([e.path, target]);
    } catch (_) {}
  }
  return newVideo;
}

// ═══════════════════════ 字幕 ═══════════════════════

const _subExts = {'.srt', '.ass', '.ssa', '.vtt', '.sub'};

/// 视频旁边是否已经有字幕文件
Future<bool> hasSubtitle(Fs fs, String base) async {
  final stem = p.basename(base);
  try {
    final items = await fs.list(p.dirname(base));
    return items.any((e) =>
        !e.isDir &&
        e.name.startsWith('$stem.') &&
        _subExts.contains(p.extension(e.name).toLowerCase()));
  } catch (_) {
    return false;
  }
}

/// 在字幕站按番号搜索，下载中文字幕（简体优先）。
/// 成功返回 (字幕内容, 语言代码如 zh-CN)，没找到返回 null
Future<(Uint8List, String)?> fetchSubtitle(
    Net net, String baseUrl, String num, void Function(String) log) async {
  final base = trimSlash(baseUrl);
  final sr = await net
      .get('$base/index.php?search=${Uri.encodeQueryComponent(num)}');
  if (sr.statusCode != 200) throw '字幕站搜索 HTTP ${sr.statusCode}';
  final sbody = decodeBody(sr);
  if (looksBlocked(sbody)) throw '字幕站被拦截（Cloudflare）';
  final sdoc = html_parser.parse(sbody);

  final key = num.toUpperCase();
  final pages = <String>[];
  for (final a in sdoc.querySelectorAll('a')) {
    final href = a.attributes['href'] ?? '';
    if (!href.contains('subs/')) continue;
    final hay = '${a.text} $href'.toUpperCase().replaceAll('_', '-');
    if (!hay.contains(key)) continue;
    final full = Uri.parse('$base/').resolve(href).toString();
    if (!pages.contains(full)) pages.add(full);
    if (pages.length >= 3) break;
  }
  if (pages.isEmpty) {
    log('   · 字幕站没有这个番号');
    return null;
  }

  final seen = <String>{};
  final langRe = RegExp(r'-([a-zA-Z]{2,3}(?:-[A-Za-z]{2,4})?)\.srt$',
      caseSensitive: false);
  String? bestUrl;
  var bestLang = '';
  var bestScore = 0;

  for (final page in pages) {
    final dr = await net.get(page);
    if (dr.statusCode != 200) continue;
    final doc = html_parser.parse(decodeBody(dr));
    for (final a in doc.querySelectorAll('a')) {
      final href = a.attributes['href'] ?? '';
      if (!href.toLowerCase().endsWith('.srt')) continue;
      final lang = langRe.firstMatch(href)?.group(1) ?? '';
      seen.add(lang.isEmpty ? '?' : lang);
      final l = lang.toLowerCase();
      var score = 0;
      if (l == 'zh-cn' || l == 'zh-hans') {
        score = 3;
      } else if (l == 'zh-tw' || l == 'zh-hant') {
        score = 2;
      } else if (l == 'zh') {
        score = 1;
      }
      if (score > bestScore) {
        bestScore = score;
        bestUrl = Uri.parse(page).resolve(href).toString();
        bestLang = lang;
      }
    }
    if (bestScore == 3) break;
  }

  if (bestUrl == null) {
    log('   · 字幕站没有中文字幕（只有：${seen.isEmpty ? '无' : seen.join(', ')}）');
    return null;
  }
  final r = await net.get(bestUrl);
  final b = r.bodyBytes;
  final text = utf8.decode(b, allowMalformed: true);
  if (r.statusCode != 200 || b.length < 200 || !text.contains('-->')) {
    log('   · 字幕下载失败：HTTP ${r.statusCode}（${b.length}字节）');
    return null;
  }
  return (b, bestLang);
}

// ═══════════════════════ 整理记录（用于撤销）═══════════════════════

final String _journalPath = p.join(_dataDir, 'journal.json');

Future<List<Map<String, dynamic>>> loadJournal() async {
  try {
    final f = File(_journalPath);
    if (!f.existsSync()) return [];
    final j = jsonDecode(await f.readAsString()) as List;
    return j.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  } catch (_) {
    return [];
  }
}

Future<void> saveJournal(List<Map<String, dynamic>> batches) async {
  try {
    final f = File(_journalPath);
    await f.parent.create(recursive: true);
    final keep =
        batches.length > 10 ? batches.sublist(batches.length - 10) : batches;
    await f.writeAsString(jsonEncode(keep));
  } catch (_) {}
}

/// 失败的文件（可以手动输入番号重试）
class _Fail {
  final String path;
  final String reason;
  _Fail(this.path, this.reason);
}

// ═══════════════════════ 屏幕常亮（原生，由打包脚本注入） ═══════════════════════

const _keepAwakeChannel = MethodChannel('app/keepawake');

Future<void> keepAwake(bool on) async {
  try {
    await _keepAwakeChannel.invokeMethod(on ? 'enable' : 'disable');
  } catch (_) {}
}

// ═══════════════════════ 文件系统（本机 / SMB 网络共享）═══════════════════════

class FsItem {
  final String path;
  final bool isDir;
  FsItem(this.path, this.isDir);
  String get name => p.basename(path);
}

abstract class Fs {
  Future<List<FsItem>> list(String dir);
  Future<bool> exists(String path);
  Future<void> mkdirs(String dir);
  Future<void> writeBytes(String path, List<int> data);
  Future<void> move(String from, String to);
  Future<void> delete(String path);
  Future<void> close();
}

class LocalFs implements Fs {
  @override
  Future<List<FsItem>> list(String dir) async {
    final out = <FsItem>[];
    await for (final e in Directory(dir).list(followLinks: false)) {
      out.add(FsItem(e.path, e is Directory));
    }
    return out;
  }

  @override
  Future<bool> exists(String path) async =>
      await FileSystemEntity.type(path) != FileSystemEntityType.notFound;

  @override
  Future<void> mkdirs(String dir) async {
    await Directory(dir).create(recursive: true);
  }

  @override
  Future<void> writeBytes(String path, List<int> data) async {
    await File(path).writeAsBytes(data);
  }

  @override
  Future<void> move(String from, String to) async {
    final f = File(from);
    try {
      await f.rename(to);
    } catch (_) {
      // 跨存储卡时 rename 会失败，改为复制后删除
      await f.copy(to);
      await f.delete();
    }
  }

  @override
  Future<void> delete(String path) async {
    if (await FileSystemEntity.isDirectory(path)) {
      await Directory(path).delete();
    } else {
      await File(path).delete();
    }
  }

  @override
  Future<void> close() async {}
}

/// SMB 网络共享（NAS、Windows 共享文件夹）。
/// 路径格式：/共享名/文件夹/文件
class SmbFs implements Fs {
  final smb.SmbConnect c;
  SmbFs(this.c);

  String _n(String path) {
    var t = path.replaceAll('\\', '/');
    if (!t.startsWith('/')) t = '/$t';
    while (t.length > 1 && t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  @override
  Future<List<FsItem>> list(String dir) async {
    final d = _n(dir);
    if (d == '/') {
      final shares = await c.listShares();
      return shares.map((e) => FsItem(_n(e.path), true)).toList();
    }
    final folder = await c.file('$d/');
    final files = await c.listFiles(folder);
    return files.map((e) => FsItem(_n(e.path), e.isDirectory())).toList();
  }

  @override
  Future<bool> exists(String path) async {
    final n = _n(path);
    try {
      final f = await c.file(n);
      if (f.isExists) return true;
    } catch (_) {}
    try {
      final f = await c.file('$n/');
      return f.isExists;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> mkdirs(String dir) async {
    final parts = _n(dir).split('/').where((e) => e.isNotEmpty).toList();
    var cur = '';
    for (var i = 0; i < parts.length; i++) {
      cur = '$cur/${parts[i]}';
      if (i == 0) continue; // 第一段是共享名，不能创建
      if (!await exists(cur)) {
        await c.createFolder(cur);
      }
    }
  }

  @override
  Future<void> writeBytes(String path, List<int> data) async {
    final n = _n(path);
    if (await exists(n)) {
      final old = await c.file(n);
      await c.delete(old);
    }
    final f = await c.createFile(n);
    final w = await c.openWrite(f);
    w.add(data);
    await w.flush();
    await w.close();
  }

  @override
  Future<void> move(String from, String to) async {
    final f = await c.file(_n(from));
    await c.rename(f, _n(to));
  }

  @override
  Future<void> delete(String path) async {
    final n = _n(path);
    final f = await c.file(n);
    if (f.isExists) {
      await c.delete(f);
    } else {
      final g = await c.file('$n/');
      await c.delete(g);
    }
  }

  @override
  Future<void> close() async {
    try {
      await c.close();
    } catch (_) {}
  }
}

/// 递归扫描目录下所有视频，返回完整路径
Future<List<String>> scanVideos(Fs fs, String root) async {
  final out = <String>[];
  final stack = <String>[root];
  while (stack.isNotEmpty) {
    final d = stack.removeLast();
    try {
      for (final e in await fs.list(d)) {
        final name = e.name;
        if (e.isDir) {
          // 跳过群晖回收站、缩略图等系统目录
          if (name.startsWith('@') ||
              name.startsWith('#') ||
              name.startsWith('.') ||
              name.startsWith('\$') ||
              name == 'System Volume Information') {
            continue;
          }
          stack.add(e.path);
        } else if (_videoExts.contains(p.extension(name).toLowerCase())) {
          out.add(e.path);
        }
      }
    } catch (_) {}
  }
  out.sort();
  return out;
}

// ═══════════════════════ 剧照 ═══════════════════════

Future<Uint8List?> _getImage(Net net, String url) async {
  try {
    final r = await net.get(url.replaceFirst(RegExp(r'^http://'), 'https://'));
    final b = r.bodyBytes;
    if (r.statusCode == 200 && b.length > 3000 && _isImage(b)) return b;
  } catch (_) {}
  return null;
}

/// 下载剧照到 dir（fanart1.jpg、fanart2.jpg…），返回成功张数。
/// 3 张一组并行下载，写入时逐张进行（网络共享更稳）
Future<int> downloadStills(Net net, Fs fs, List<String> urls, String dir,
    int max, void Function(String) rec) async {
  final list = (max > 0 && urls.length > max) ? urls.sublist(0, max) : urls;
  if (list.isEmpty) return 0;
  await fs.mkdirs(dir);
  var ok = 0;
  for (var i = 0; i < list.length; i += 3) {
    final end = i + 3 > list.length ? list.length : i + 3;
    final datas = await Future.wait([
      for (var k = i; k < end; k++) _getImage(net, list[k]),
    ]);
    for (var k = i; k < end; k++) {
      final b = datas[k - i];
      if (b == null) continue;
      final path = p.join(dir, 'fanart${k + 1}.jpg');
      await fs.writeBytes(path, b);
      rec(path);
      ok++;
    }
  }
  return ok;
}

// ═══════════════════════ 翻译 ═══════════════════════

Future<String?> _googleTr(Net net, String text, String to, String from) async {
  final url = 'https://translate.googleapis.com/translate_a/single'
      '?client=gtx&sl=$from&tl=$to&dt=t&q=${Uri.encodeQueryComponent(text)}';
  final r = await net.get(url);
  if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
  final j = jsonDecode(utf8.decode(r.bodyBytes)) as List;
  final segs = j[0] as List;
  return segs.map((e) => ((e as List)[0] ?? '').toString()).join();
}

Future<String?> _myMemoryTr(Net net, String text, String to) async {
  final lp = Uri.encodeQueryComponent('ja|$to');
  final r = await net.get('https://api.mymemory.translated.net/get'
      '?q=${Uri.encodeQueryComponent(text)}&langpair=$lp');
  if (r.statusCode != 200) throw 'HTTP ${r.statusCode}';
  final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
  final t = (j['responseData'] as Map?)?['translatedText'];
  return t?.toString();
}

/// 先用谷歌翻译，失败再用 MyMemory（只对日语原文有效）
Future<String?> translateText(Net net, String text, String to,
    {String from = 'auto',
    bool fallback = true,
    void Function(String)? log}) async {
  try {
    final t = await _googleTr(net, text, to, from);
    if (t != null && t.trim().isNotEmpty) return t.trim();
  } catch (e) {
    log?.call('   · 谷歌翻译失败：${errText(e)}');
  }
  if (fallback && (from == 'ja' || from == 'auto')) {
    try {
      final t = await _myMemoryTr(net, text, to);
      if (t != null &&
          t.trim().isNotEmpty &&
          !t.contains('MYMEMORY WARNING')) {
        return t.trim();
      }
    } catch (e) {
      log?.call('   · 备用翻译失败：${errText(e)}');
    }
  }
  return null;
}

/// 批量翻译一组短词（类别），返回数量一致才算成功
Future<List<String>?> translateList(Net net, List<String> items, String to,
    {void Function(String)? log}) async {
  final t = await translateText(net, items.join('\n'), to,
      fallback: false, log: log);
  if (t == null) return null;
  final parts =
      t.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  if (parts.length != items.length) return null;
  final out = <String>[];
  for (final x in parts) {
    if (!out.contains(x)) out.add(x);
  }
  return out;
}

// ═══════════════════════ 网络共享：选择文件夹 ═══════════════════════

class RemoteDirPicker extends StatefulWidget {
  final Fs fs;
  final String initial;
  const RemoteDirPicker({super.key, required this.fs, this.initial = '/'});

  @override
  State<RemoteDirPicker> createState() => _RemoteDirPickerState();
}

class _RemoteDirPickerState extends State<RemoteDirPicker> {
  String cur = '/';
  List<FsItem> dirs = [];
  bool loading = true;
  String? err;

  @override
  void initState() {
    super.initState();
    _load(widget.initial.isEmpty ? '/' : widget.initial, fallbackRoot: true);
  }

  Future<void> _load(String path, {bool fallbackRoot = false}) async {
    if (mounted) {
      setState(() {
        loading = true;
        err = null;
      });
    }
    try {
      final all = await widget.fs.list(path);
      final d = all.where((e) => e.isDir && !e.name.endsWith('\$')).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        cur = path;
        dirs = d;
        loading = false;
      });
    } catch (e) {
      if (fallbackRoot && path != '/') {
        await _load('/');
        return;
      }
      if (!mounted) return;
      setState(() {
        err = errText(e);
        loading = false;
      });
    }
  }

  String _parent(String path) {
    final pp = p.dirname(path);
    return (pp == '.' || pp.isEmpty) ? '/' : pp;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(cur == '/' ? '选择共享文件夹' : cur,
          style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: loading
            ? const Center(child: CircularProgressIndicator())
            : err != null
                ? Text('读取失败：$err')
                : ListView(
                    children: [
                      if (cur != '/')
                        ListTile(
                          leading: const Icon(Icons.arrow_upward),
                          title: const Text('上一级'),
                          onTap: () => _load(_parent(cur)),
                        ),
                      for (final d in dirs)
                        ListTile(
                          leading: const Icon(Icons.folder),
                          title: Text(d.name),
                          onTap: () => _load(d.path),
                        ),
                      if (dirs.isEmpty) const ListTile(title: Text('（没有子文件夹）')),
                    ],
                  ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
            onPressed: cur == '/' ? null : () => Navigator.pop(context, cur),
            child: const Text('选择此文件夹')),
      ],
    );
  }
}

// ═══════════════════════ 连接测试 ═══════════════════════

class DiagCheck {
  final String name;
  final Future<(bool, String)> Function(Net net) run;
  DiagCheck(this.name, this.run);
}

/// 打开一个网页，判断能不能正常访问
Future<(bool, String)> pageCheck(Net net, String url,
    {Map<String, String>? extra}) async {
  if (url.trim().isEmpty) return (false, '没有填写网址');
  final r = await net.get(trimSlash(url), extra: extra);
  final body = decodeBody(r);
  if (looksBlocked(body)) {
    return (false, 'HTTP ${r.statusCode}，被 Cloudflare 拦截（可以试试代理）');
  }
  if (r.statusCode == 200) return (true, '页面正常');
  return (false, 'HTTP ${r.statusCode}');
}

class DiagDialog extends StatefulWidget {
  final List<DiagCheck> checks;
  final String proxy;
  const DiagDialog({super.key, required this.checks, required this.proxy});

  @override
  State<DiagDialog> createState() => _DiagDialogState();
}

class _DiagDialogState extends State<DiagDialog> {
  late final Net net;
  late List<int> state; // 0=测试中 1=正常 2=失败
  late List<String> detail;

  @override
  void initState() {
    super.initState();
    net = Net(widget.proxy, timeout: const Duration(seconds: 12), tries: 1);
    state = List.filled(widget.checks.length, 0);
    detail = List.filled(widget.checks.length, '测试中…');
    _runAll();
  }

  @override
  void dispose() {
    net.close();
    super.dispose();
  }

  Future<void> _runAll() async {
    if (mounted) {
      setState(() {
        state = List.filled(widget.checks.length, 0);
        detail = List.filled(widget.checks.length, '测试中…');
      });
    }
    await Future.wait([
      for (var i = 0; i < widget.checks.length; i++) _runOne(i),
    ]);
  }

  Future<void> _runOne(int i) async {
    final sw = Stopwatch()..start();
    try {
      final r =
          await widget.checks[i].run(net).timeout(const Duration(seconds: 20));
      final ms = sw.elapsedMilliseconds;
      if (!mounted) return;
      setState(() {
        state[i] = r.$1 ? 1 : 2;
        detail[i] = '${r.$2}（$ms 毫秒）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        state[i] = 2;
        detail[i] = errText(e);
      });
    }
  }

  String _report() {
    final b = StringBuffer('连接测试 v$appVersion\n');
    for (var i = 0; i < widget.checks.length; i++) {
      final mark = state[i] == 1 ? '✓' : (state[i] == 2 ? '✗' : '…');
      b.writeln('$mark ${widget.checks[i].name}：${detail[i]}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('连接测试'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < widget.checks.length; i++)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: state[i] == 0
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(
                        state[i] == 1 ? Icons.check_circle : Icons.cancel,
                        color: state[i] == 1 ? Colors.green : Colors.red,
                      ),
                title: Text(widget.checks[i].name),
                subtitle: Text(detail[i]),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _report()));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('测试结果已复制')),
            );
          },
          child: const Text('复制结果'),
        ),
        TextButton(onPressed: _runAll, child: const Text('重新测试')),
        FilledButton(
            onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }
}

// ═══════════════════════ 影视库（电脑版）═══════════════════════

const _imgExts = {'.jpg', '.jpeg', '.png', '.webp'};

/// 影视库里的一部影片
class LibItem {
  final String path; // 视频完整路径
  String num = '';
  String title = '';
  String origTitle = '';
  String date = '';
  int runtime = 0;
  String studio = '';
  String director = '';
  String series = '';
  List<String> genres = [];
  List<String> actors = [];
  List<String> tags = [];
  bool hasNfo = false;
  int nfoMtime = 0;
  int nfoSize = 0;
  int added = 0; // 视频文件的修改时间（毫秒），用作「添加时间」
  String poster = '';
  String fanart = '';
  bool hasStills = false;

  LibItem(this.path);

  String get dir => p.dirname(path);
  String get stem => p.basenameWithoutExtension(path);
  String get year => date.length >= 4 ? date.substring(0, 4) : '';

  /// 收藏、已看的记录用番号做键，整理移动文件后也不会丢；没有番号就用路径
  String get key => num.isNotEmpty ? num : path;

  /// 有 NFO 但找不到封面
  bool get incomplete => hasNfo && poster.isEmpty && fanart.isEmpty;

  void copyMetaFrom(LibItem o) {
    num = o.num;
    title = o.title;
    origTitle = o.origTitle;
    date = o.date;
    runtime = o.runtime;
    studio = o.studio;
    director = o.director;
    series = o.series;
    genres = List.of(o.genres);
    actors = List.of(o.actors);
    tags = List.of(o.tags);
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'num': num,
        'title': title,
        'origTitle': origTitle,
        'date': date,
        'runtime': runtime,
        'studio': studio,
        'director': director,
        'series': series,
        'genres': genres,
        'actors': actors,
        'tags': tags,
        'hasNfo': hasNfo,
        'nfoMtime': nfoMtime,
        'nfoSize': nfoSize,
        'added': added,
        'poster': poster,
        'fanart': fanart,
        'hasStills': hasStills,
      };

  factory LibItem.fromJson(Map<String, dynamic> j) {
    final it = LibItem(j['path'] as String);
    it.num = (j['num'] ?? '') as String;
    it.title = (j['title'] ?? '') as String;
    it.origTitle = (j['origTitle'] ?? '') as String;
    it.date = (j['date'] ?? '') as String;
    it.runtime = (j['runtime'] ?? 0) as int;
    it.studio = (j['studio'] ?? '') as String;
    it.director = (j['director'] ?? '') as String;
    it.series = (j['series'] ?? '') as String;
    it.genres = ((j['genres'] ?? []) as List).cast<String>().toList();
    it.actors = ((j['actors'] ?? []) as List).cast<String>().toList();
    it.tags = ((j['tags'] ?? []) as List).cast<String>().toList();
    it.hasNfo = (j['hasNfo'] ?? false) as bool;
    it.nfoMtime = (j['nfoMtime'] ?? 0) as int;
    it.nfoSize = (j['nfoSize'] ?? 0) as int;
    it.added = (j['added'] ?? 0) as int;
    it.poster = (j['poster'] ?? '') as String;
    it.fanart = (j['fanart'] ?? '') as String;
    it.hasStills = (j['hasStills'] ?? false) as bool;
    return it;
  }
}

// ---------- 读取 NFO（简单的标签提取，兼容 CDATA 和其他刮削器的 NFO）----------

String _xmlText(String s) {
  var t = s.trim();
  final cd = RegExp(r'^<!\[CDATA\[(.*)\]\]>$', dotAll: true).firstMatch(t);
  if (cd != null) t = cd.group(1)!;
  return t
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&')
      .trim();
}

String _nfoFirst(String xml, String tag) {
  final m =
      RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true).firstMatch(xml);
  return m == null ? '' : _xmlText(m.group(1)!);
}

List<String> _nfoAll(String xml, String tag) {
  final out = <String>[];
  for (final m
      in RegExp('<$tag(?:\\s[^>]*)?>(.*?)</$tag>', dotAll: true)
          .allMatches(xml)) {
    final v = _xmlText(m.group(1)!);
    if (v.isNotEmpty && !out.contains(v)) out.add(v);
  }
  return out;
}

void applyNfo(LibItem it, String xml) {
  var num = _nfoFirst(xml, 'num');
  if (num.isEmpty) {
    final u = RegExp(r'<uniqueid[^>]*type="num"[^>]*>(.*?)</uniqueid>',
            dotAll: true)
        .firstMatch(xml);
    if (u != null) num = _xmlText(u.group(1)!);
  }
  if (num.isEmpty) num = extractCode(it.stem) ?? '';
  it.num = num;

  var title = _nfoFirst(xml, 'title');
  if (num.isNotEmpty && title.toUpperCase().startsWith(num.toUpperCase())) {
    title = title.substring(num.length).trim();
  }
  it.title = title.isEmpty ? it.stem : title;
  it.origTitle = _nfoFirst(xml, 'originaltitle');

  var date = _nfoFirst(xml, 'premiered');
  if (date.isEmpty) date = _nfoFirst(xml, 'releasedate');
  if (date.isEmpty) date = _nfoFirst(xml, 'year');
  it.date = date;
  it.runtime = int.tryParse(_nfoFirst(xml, 'runtime')) ?? 0;
  it.studio = _nfoFirst(xml, 'studio');
  it.director = _nfoFirst(xml, 'director');

  final setRaw =
      RegExp(r'<set(?:\s[^>]*)?>(.*?)</set>', dotAll: true).firstMatch(xml)
              ?.group(1) ??
          '';
  final setName = _nfoFirst(setRaw, 'name');
  it.series = setName.isNotEmpty
      ? setName
      : (setRaw.contains('<') ? '' : _xmlText(setRaw));

  it.genres = _nfoAll(xml, 'genre');
  it.tags = _nfoAll(xml, 'tag').where((t) => !it.genres.contains(t)).toList();

  final actors = <String>[];
  for (final m in RegExp(r'<actor(?:\s[^>]*)?>(.*?)</actor>', dotAll: true)
      .allMatches(xml)) {
    final n = _nfoFirst(m.group(1)!, 'name');
    if (n.isNotEmpty && !actors.contains(n)) actors.add(n);
  }
  it.actors = actors;
}

/// 影视库的数据：影片文件夹、影片列表、收藏和已看记录
class LibraryStore extends ChangeNotifier {
  final folders = <String>[];
  List<LibItem> items = [];
  final favs = <String>{};
  final seen = <String>{};
  bool scanning = false;
  String scanMsg = '';
  bool loaded = false;

  String get _indexFile => p.join(_dataDir, 'library.json');
  String get _stateFile => p.join(_dataDir, 'library_state.json');

  Future<void> load() async {
    if (loaded) return;
    loaded = true;
    try {
      final f = File(_indexFile);
      if (f.existsSync()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        folders
          ..clear()
          ..addAll((j['folders'] as List).cast<String>());
        items = (j['items'] as List)
            .map((e) => LibItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
    } catch (_) {}
    try {
      final f = File(_stateFile);
      if (f.existsSync()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        favs
          ..clear()
          ..addAll((j['fav'] as List).cast<String>());
        seen
          ..clear()
          ..addAll((j['seen'] as List).cast<String>());
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _saveIndex() async {
    try {
      final f = File(_indexFile);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode({
        'folders': folders,
        'items': items.map((e) => e.toJson()).toList(),
      }));
    } catch (_) {}
  }

  Future<void> _saveState() async {
    try {
      final f = File(_stateFile);
      await f.parent.create(recursive: true);
      await f.writeAsString(
          jsonEncode({'fav': favs.toList(), 'seen': seen.toList()}));
    } catch (_) {}
  }

  bool isFav(LibItem it) => favs.contains(it.key);
  bool isSeen(LibItem it) => seen.contains(it.key);

  void toggleFav(LibItem it) {
    if (!favs.remove(it.key)) favs.add(it.key);
    _saveState();
    notifyListeners();
  }

  void setSeen(LibItem it, bool v) {
    if (v) {
      seen.add(it.key);
    } else {
      seen.remove(it.key);
    }
    _saveState();
    notifyListeners();
  }

  /// 添加影片文件夹。已被包含的返回 false；新文件夹包含了旧的，会合并
  Future<bool> addFolder(String dir) async {
    final n = p.normalize(dir);
    if (folders.any((f) => p.equals(f, n) || p.isWithin(f, n))) return false;
    folders.removeWhere((f) => p.isWithin(n, f));
    folders.add(n);
    await _saveIndex();
    notifyListeners();
    return true;
  }

  Future<void> removeFolder(String dir) async {
    folders.removeWhere((f) => p.equals(f, dir));
    items.removeWhere((it) => p.isWithin(dir, it.path));
    await _saveIndex();
    notifyListeners();
  }

  /// 重新扫描所有影片文件夹。NFO 没有变化的影片直接沿用上次的结果，所以很快
  Future<void> rescan() async {
    if (scanning) return;
    scanning = true;
    scanMsg = '正在扫描…';
    notifyListeners();
    try {
      final old = {for (final it in items) it.path: it};
      final out = <LibItem>[];
      for (final root in List<String>.of(folders)) {
        await _scanRoot(root, old, out);
      }
      items = out;
      await _saveIndex();
    } catch (_) {
    } finally {
      scanning = false;
      scanMsg = '';
      notifyListeners();
    }
  }

  Future<void> _scanRoot(
      String root, Map<String, LibItem> old, List<LibItem> out) async {
    final stack = <String>[root];
    var n = 0;
    while (stack.isNotEmpty) {
      final dir = stack.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = await Directory(dir).list(followLinks: false).toList();
      } catch (_) {
        continue;
      }
      final names = <String, String>{}; // 小写文件名 → 实际文件名
      final files = <File>[];
      for (final e in entries) {
        final name = p.basename(e.path);
        names[name.toLowerCase()] = name;
        if (e is Directory) {
          if (name.startsWith('@') ||
              name.startsWith('#') ||
              name.startsWith('.') ||
              name.startsWith('\$') ||
              name == 'System Volume Information' ||
              name == 'extrafanart' ||
              name.endsWith('-extrafanart')) {
            continue;
          }
          stack.add(e.path);
        } else if (e is File &&
            _videoExts.contains(p.extension(name).toLowerCase())) {
          files.add(e);
        }
      }
      for (final f in files) {
        out.add(await _buildItem(f, names, old[f.path]));
        n++;
        if (n % 20 == 0) {
          scanMsg = '已扫描 $n 部…';
          notifyListeners();
          await Future<void>.delayed(Duration.zero);
        }
      }
    }
  }

  Future<LibItem> _buildItem(
      File f, Map<String, String> names, LibItem? cached) async {
    final path = f.path;
    final dir = p.dirname(path);
    final stem = p.basenameWithoutExtension(path);
    final it = LibItem(path);
    try {
      it.added = (await f.lastModified()).millisecondsSinceEpoch;
    } catch (_) {}

    final nfoName = names['$stem.nfo'.toLowerCase()];
    var ok = false;
    if (nfoName != null) {
      try {
        final nfo = File(p.join(dir, nfoName));
        final st = await nfo.stat();
        final mt = st.modified.millisecondsSinceEpoch;
        if (cached != null &&
            cached.hasNfo &&
            cached.nfoMtime == mt &&
            cached.nfoSize == st.size) {
          it.copyMetaFrom(cached); // NFO 没变，沿用旧结果
        } else {
          applyNfo(
              it, utf8.decode(await nfo.readAsBytes(), allowMalformed: true));
        }
        it.hasNfo = true;
        it.nfoMtime = mt;
        it.nfoSize = st.size;
        ok = true;
      } catch (_) {}
    }
    if (!ok) {
      it.num = extractCode(stem) ?? '';
      it.title = stem;
    }

    String pick(List<String> cands) {
      for (final c in cands) {
        final real = names[c.toLowerCase()];
        if (real != null) return p.join(dir, real);
      }
      return '';
    }

    it.poster = pick([
      '$stem-poster.jpg',
      '$stem-poster.png',
      '$stem-poster.jpeg',
      'poster.jpg',
      'poster.png',
      'folder.jpg',
      'cover.jpg',
    ]);
    it.fanart = pick([
      '$stem-fanart.jpg',
      '$stem-fanart.png',
      'fanart.jpg',
      'backdrop.jpg',
      '$stem-thumb.jpg',
    ]);
    it.hasStills = names.containsKey('extrafanart') ||
        names.containsKey('$stem-extrafanart'.toLowerCase());
    return it;
  }

  /// 修改标题（写回 NFO）。成功返回 null，失败返回原因
  Future<String?> editTitle(LibItem it, String newTitle) async {
    if (!it.hasNfo) return '这部影片还没有 NFO，请先刮削';
    try {
      final nfo = File(p.join(it.dir, '${it.stem}.nfo'));
      final xml = utf8.decode(await nfo.readAsBytes(), allowMalformed: true);
      final raw = _nfoFirst(xml, 'title');
      final hadNum = it.num.isNotEmpty &&
          raw.toUpperCase().startsWith(it.num.toUpperCase());
      final newRaw = hadNum ? '${it.num} $newTitle' : newTitle;
      final re = RegExp(r'<title(?:\s[^>]*)?>.*?</title>', dotAll: true);
      if (!re.hasMatch(xml)) return 'NFO 里没有找到标题标签';
      final out = xml.replaceFirstMapped(re, (_) => '<title>${_x(newRaw)}</title>');
      await nfo.writeAsString(out);
      final st = await nfo.stat();
      it.title = newTitle;
      it.nfoMtime = st.modified.millisecondsSinceEpoch;
      it.nfoSize = st.size;
      await _saveIndex();
      notifyListeners();
      return null;
    } catch (e) {
      return errText(e);
    }
  }
}

final libStore = LibraryStore();

// ═══════════════════════ 影视库：界面 ═══════════════════════

Future<String?> pickOption(
    BuildContext context, String title, Map<String, int> options) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _PickDialog(title: title, options: options),
  );
}

class _PickDialog extends StatefulWidget {
  final String title;
  final Map<String, int> options;
  const _PickDialog({required this.title, required this.options});

  @override
  State<_PickDialog> createState() => _PickDialogState();
}

class _PickDialogState extends State<_PickDialog> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final all = widget.options.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final shown = q.isEmpty
        ? all
        : all.where((e) => e.key.toLowerCase().contains(q.toLowerCase())).toList();
    return AlertDialog(
      title: Text('选择${widget.title}'),
      content: SizedBox(
        width: 360,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '搜索',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => q = v.trim()),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('没有匹配的项目'))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        title: Text(shown[i].key),
                        trailing: Text('${shown[i].value} 部'),
                        onTap: () => Navigator.pop(context, shown[i].key),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
      ],
    );
  }
}

/// 演员 / 厂商 / 类别 排行，点击可筛选
class StatsPage extends StatelessWidget {
  final Map<String, int> actors;
  final Map<String, int> studios;
  final Map<String, int> genres;
  const StatsPage({
    super.key,
    required this.actors,
    required this.studios,
    required this.genres,
  });

  Widget _rank(BuildContext context, String kind, Map<String, int> m) {
    final e = m.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    if (e.isEmpty) return const Center(child: Text('暂无数据'));
    return ListView.builder(
      itemCount: e.length,
      itemBuilder: (_, i) => ListTile(
        dense: true,
        leading: Text('${i + 1}'),
        title: Text(e[i].key),
        trailing: Text('${e[i].value} 部'),
        onTap: () => Navigator.pop(context, (kind, e[i].key)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('统计（点击可筛选）'),
          bottom: const TabBar(
            tabs: [Tab(text: '演员'), Tab(text: '厂商'), Tab(text: '类别')],
          ),
        ),
        body: TabBarView(
          children: [
            _rank(context, 'actor', actors),
            _rank(context, 'studio', studios),
            _rank(context, 'genre', genres),
          ],
        ),
      ),
    );
  }
}

Future<void> _openFile(String path) async {
  if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [path]);
  } else {
    await Process.run('xdg-open', [path]);
  }
}

Future<void> _showInFolder(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else {
    await Process.run('xdg-open', [p.dirname(path)]);
  }
}

Widget _posterImage(String path, {BoxFit fit = BoxFit.cover, int? cacheWidth}) {
  return Image.file(
    File(path),
    fit: fit,
    cacheWidth: cacheWidth,
    errorBuilder: (_, __, ___) => Container(
      color: Colors.black12,
      child: const Center(child: Icon(Icons.broken_image)),
    ),
  );
}

class LibraryPage extends StatefulWidget {
  /// 对一批影片重新刮削（由刮削页面执行）
  final Future<void> Function(List<LibItem> items) onRescrape;
  const LibraryPage({super.key, required this.onRescrape});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _searchCtl = TextEditingController();
  String _q = '';
  String _sort = 'added';
  bool _grid = true;
  String _quick = 'all'; // all fav unseen unscraped incomplete dup
  String? _actor, _genre, _studio, _series, _year;

  @override
  void initState() {
    super.initState();
    libStore.addListener(_onStore);
    libStore.load().then((_) {
      if (libStore.folders.isNotEmpty) libStore.rescan();
    });
  }

  @override
  void dispose() {
    libStore.removeListener(_onStore);
    _searchCtl.dispose();
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  bool get _hasFilter =>
      _actor != null ||
      _genre != null ||
      _studio != null ||
      _series != null ||
      _year != null ||
      _quick != 'all';

  void _clearFilters() {
    _actor = _genre = _studio = _series = _year = null;
    _quick = 'all';
    _q = '';
    _searchCtl.clear();
  }

  Map<String, int> _count(List<String> Function(LibItem) f) {
    final m = <String, int>{};
    for (final it in libStore.items) {
      for (final k in f(it)) {
        if (k.isEmpty) continue;
        m[k] = (m[k] ?? 0) + 1;
      }
    }
    return m;
  }

  List<LibItem> _filtered() {
    final q = _q.trim().toLowerCase();
    final dupKeys = <String>{};
    if (_quick == 'dup') {
      final cnt = <String, int>{};
      for (final it in libStore.items) {
        if (it.num.isNotEmpty) cnt[it.num] = (cnt[it.num] ?? 0) + 1;
      }
      cnt.forEach((k, v) {
        if (v > 1) dupKeys.add(k);
      });
    }
    final list = libStore.items.where((it) {
      if (_actor != null && !it.actors.contains(_actor)) return false;
      if (_genre != null && !it.genres.contains(_genre)) return false;
      if (_studio != null && it.studio != _studio) return false;
      if (_series != null && it.series != _series) return false;
      if (_year != null && it.year != _year) return false;
      switch (_quick) {
        case 'fav':
          if (!libStore.isFav(it)) return false;
          break;
        case 'unseen':
          if (libStore.isSeen(it)) return false;
          break;
        case 'unscraped':
          if (it.hasNfo) return false;
          break;
        case 'incomplete':
          if (!it.incomplete) return false;
          break;
        case 'dup':
          if (!dupKeys.contains(it.num)) return false;
          break;
      }
      if (q.isNotEmpty) {
        final hay =
            '${it.num} ${it.title} ${it.origTitle} ${it.actors.join(' ')} ${it.studio} ${it.series}'
                .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
    switch (_sort) {
      case 'date':
        list.sort((a, b) => b.date.compareTo(a.date));
        break;
      case 'num':
        list.sort((a, b) => a.num.compareTo(b.num));
        break;
      case 'title':
        list.sort((a, b) => a.title.compareTo(b.title));
        break;
      default:
        list.sort((a, b) => b.added.compareTo(a.added));
    }
    return list;
  }

  Future<void> _open(LibItem it) async {
    final r = await Navigator.push<(String, String)>(
      context,
      MaterialPageRoute(builder: (_) => LibraryDetailPage(item: it)),
    );
    if (r == null || !mounted) return;
    if (r.$1 == 'rescrape') {
      await widget.onRescrape([it]);
      return;
    }
    _applyPick(r.$1, r.$2);
  }

  void _applyPick(String kind, String value) {
    setState(() {
      _clearFilters();
      switch (kind) {
        case 'actor':
          _actor = value;
          break;
        case 'genre':
          _genre = value;
          break;
        case 'studio':
          _studio = value;
          break;
        case 'series':
          _series = value;
          break;
      }
    });
  }

  Future<void> _openStats() async {
    final r = await Navigator.push<(String, String)>(
      context,
      MaterialPageRoute(
        builder: (_) => StatsPage(
          actors: _count((e) => e.actors),
          studios: _count((e) => [e.studio]),
          genres: _count((e) => e.genres),
        ),
      ),
    );
    if (r != null && mounted) _applyPick(r.$1, r.$2);
  }

  Future<void> _openFilter() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) {
          Widget row(String label, String? value, Map<String, int> options,
              void Function(String?) set) {
            return ListTile(
              title: Text(label),
              subtitle: Text(value ?? '不限'),
              trailing: value == null
                  ? const Icon(Icons.chevron_right)
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        set(null);
                        setM(() {});
                        setState(() {});
                      },
                    ),
              onTap: () async {
                final v = await pickOption(ctx, label, options);
                if (v != null) {
                  set(v);
                  setM(() {});
                  setState(() {});
                }
              },
            );
          }

          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                row('演员', _actor, _count((e) => e.actors), (v) => _actor = v),
                row('类别', _genre, _count((e) => e.genres), (v) => _genre = v),
                row('厂商', _studio, _count((e) => [e.studio]),
                    (v) => _studio = v),
                row('系列', _series, _count((e) => [e.series]),
                    (v) => _series = v),
                row('年份', _year, _count((e) => [e.year]), (v) => _year = v),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: TextButton(
                    onPressed: () {
                      setState(_clearFilters);
                      Navigator.pop(ctx);
                    },
                    child: const Text('清除全部筛选'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _manageFolders() async {
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => AlertDialog(
          title: const Text('影片文件夹'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (libStore.folders.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('还没有添加文件夹'),
                    ),
                  for (final f in libStore.folders)
                    ListTile(
                      dense: true,
                      title: Text(f),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '从影视库移除（不会删除任何文件）',
                        onPressed: () async {
                          await libStore.removeFolder(f);
                          setM(() {});
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final d = await FilePicker.platform
                    .getDirectoryPath(dialogTitle: '选择影片文件夹');
                if (d != null) {
                  final added = await libStore.addFolder(d);
                  setM(() {});
                  if (added) libStore.rescan();
                }
              },
              child: const Text('添加文件夹'),
            ),
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('完成')),
          ],
        ),
      ),
    );
  }

  Future<void> _fix(List<LibItem> list) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('补刮？'),
        content: Text('将对 ${list.length} 部未刮削或缺封面的影片重新刮削，'
            '会覆盖已有的 NFO 和封面，需要一些时间。\n\n'
            '过程和结果会显示在「刮削」页面里。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始补刮')),
        ],
      ),
    );
    if (yes == true) await widget.onRescrape(list);
  }

  Widget _badges(LibItem it) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (libStore.isFav(it))
          const Icon(Icons.favorite, color: Colors.redAccent, size: 20),
        if (libStore.isSeen(it))
          const Icon(Icons.check_circle, color: Colors.green, size: 20),
      ],
    );
  }

  Widget _card(LibItem it) {
    final img = it.poster.isNotEmpty ? it.poster : it.fanart;
    return InkWell(
      onTap: () => _open(it),
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  img.isEmpty
                      ? Container(
                          color: Colors.black12,
                          child: const Icon(Icons.movie, size: 48),
                        )
                      : _posterImage(img, cacheWidth: 380),
                  Positioned(top: 4, right: 4, child: _badges(it)),
                  if (!it.hasNfo)
                    Positioned(
                      left: 4,
                      top: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        color: Colors.orange,
                        child: const Text('未刮削',
                            style:
                                TextStyle(color: Colors.white, fontSize: 11)),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.num.isEmpty ? '（无番号）' : it.num,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(it.title,
                      style: const TextStyle(fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(LibItem it) {
    final img = it.poster.isNotEmpty ? it.poster : it.fanart;
    return ListTile(
      leading: SizedBox(
        width: 44,
        height: 64,
        child: img.isEmpty
            ? const Icon(Icons.movie)
            : _posterImage(img, cacheWidth: 120),
      ),
      title: Text('${it.num.isEmpty ? '' : '${it.num}  '}${it.title}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (it.actors.isNotEmpty) it.actors.take(3).join('、'),
          if (it.studio.isNotEmpty) it.studio,
          if (it.date.isNotEmpty) it.date,
          if (!it.hasNfo) '未刮削',
        ].join('  ·  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _badges(it),
      onTap: () => _open(it),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered();
    final fixable = list.where((e) => !e.hasNfo || e.incomplete).toList();
    const quicks = [
      ['all', '全部'],
      ['fav', '收藏'],
      ['unseen', '未看'],
      ['unscraped', '未刮削'],
      ['incomplete', '缺封面'],
      ['dup', '重复番号'],
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('影视库　${list.length} / ${libStore.items.length}'),
        actions: [
          IconButton(
            tooltip: _grid ? '切换为列表' : '切换为封面墙',
            icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
            onPressed: () => setState(() => _grid = !_grid),
          ),
          IconButton(
            tooltip: '筛选',
            icon: Icon(Icons.filter_alt,
                color: _hasFilter ? Colors.orange : null),
            onPressed: _openFilter,
          ),
          IconButton(
            tooltip: '统计',
            icon: const Icon(Icons.bar_chart),
            onPressed: libStore.items.isEmpty ? null : _openStats,
          ),
          IconButton(
            tooltip: '重新扫描',
            icon: const Icon(Icons.refresh),
            onPressed: libStore.scanning ? null : () => libStore.rescan(),
          ),
          IconButton(
            tooltip: '管理影片文件夹',
            icon: const Icon(Icons.folder_special),
            onPressed: _manageFolders,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtl,
                    decoration: const InputDecoration(
                      hintText: '搜索番号、标题、演员、厂商、系列',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _sort,
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: 'added', child: Text('按添加时间')),
                    DropdownMenuItem(value: 'date', child: Text('按发行日期')),
                    DropdownMenuItem(value: 'num', child: Text('按番号')),
                    DropdownMenuItem(value: 'title', child: Text('按标题')),
                  ],
                  onChanged: (v) => setState(() => _sort = v ?? 'added'),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                for (final q in quicks)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(q[1]),
                      selected: _quick == q[0],
                      onSelected: (_) => setState(() => _quick = q[0]),
                    ),
                  ),
              ],
            ),
          ),
          if (_actor != null ||
              _genre != null ||
              _studio != null ||
              _series != null ||
              _year != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  children: [
                    if (_actor != null)
                      InputChip(
                          label: Text('演员：$_actor'),
                          onDeleted: () => setState(() => _actor = null)),
                    if (_genre != null)
                      InputChip(
                          label: Text('类别：$_genre'),
                          onDeleted: () => setState(() => _genre = null)),
                    if (_studio != null)
                      InputChip(
                          label: Text('厂商：$_studio'),
                          onDeleted: () => setState(() => _studio = null)),
                    if (_series != null)
                      InputChip(
                          label: Text('系列：$_series'),
                          onDeleted: () => setState(() => _series = null)),
                    if (_year != null)
                      InputChip(
                          label: Text('年份：$_year'),
                          onDeleted: () => setState(() => _year = null)),
                  ],
                ),
              ),
            ),
          if (libStore.scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const LinearProgressIndicator(),
                  Text(libStore.scanMsg, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          if (fixable.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: TextButton.icon(
                  onPressed: () => _fix(fixable),
                  icon: const Icon(Icons.auto_fix_high),
                  label: Text('补刮当前列表中的 ${fixable.length} 部（未刮削 / 缺封面）'),
                ),
              ),
            ),
          Expanded(
            child: libStore.folders.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('影视库还是空的，先添加存放影片的文件夹'),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: _manageFolders,
                          icon: const Icon(Icons.create_new_folder),
                          label: const Text('添加影片文件夹'),
                        ),
                      ],
                    ),
                  )
                : list.isEmpty
                    ? Center(
                        child: Text(libStore.scanning ? '正在扫描…' : '没有符合条件的影片'))
                    : (_grid
                        ? GridView.builder(
                            padding: const EdgeInsets.all(8),
                            gridDelegate:
                                const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 190,
                              mainAxisExtent: 330,
                            ),
                            itemCount: list.length,
                            itemBuilder: (_, i) => _card(list[i]),
                          )
                        : ListView.builder(
                            itemCount: list.length,
                            itemBuilder: (_, i) => _tile(list[i]),
                          )),
          ),
        ],
      ),
    );
  }
}

class LibraryDetailPage extends StatefulWidget {
  final LibItem item;
  const LibraryDetailPage({super.key, required this.item});

  @override
  State<LibraryDetailPage> createState() => _LibraryDetailPageState();
}

class _LibraryDetailPageState extends State<LibraryDetailPage> {
  List<String> _stills = [];

  @override
  void initState() {
    super.initState();
    libStore.addListener(_onStore);
    _loadStills();
  }

  @override
  void dispose() {
    libStore.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  Future<void> _loadStills() async {
    final it = widget.item;
    final out = <String>[];
    for (final d in [
      p.join(it.dir, 'extrafanart'),
      p.join(it.dir, '${it.stem}-extrafanart'),
    ]) {
      try {
        final dir = Directory(d);
        if (!await dir.exists()) continue;
        final files = <String>[];
        await for (final e in dir.list()) {
          if (e is File && _imgExts.contains(p.extension(e.path).toLowerCase())) {
            files.add(e.path);
          }
        }
        files.sort();
        out.addAll(files);
      } catch (_) {}
    }
    if (mounted) setState(() => _stills = out);
  }

  void _snack(String t) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  Future<void> _play() async {
    final it = widget.item;
    try {
      await _openFile(it.path);
      libStore.setSeen(it, true);
    } catch (e) {
      _snack('无法打开：${errText(e)}');
    }
  }

  Future<void> _showFolder() async {
    try {
      await _showInFolder(widget.item.path);
    } catch (e) {
      _snack('无法打开：${errText(e)}');
    }
  }

  Future<void> _editTitle() async {
    final it = widget.item;
    final c = TextEditingController(text: it.title);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改标题'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: c,
            autofocus: true,
            maxLines: null,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (v == null || v.trim().isEmpty || v.trim() == it.title) return;
    final err = await libStore.editTitle(it, v.trim());
    _snack(err ?? '标题已修改，并写回了 NFO');
  }

  Widget _info(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 72,
              child: Text(label, style: const TextStyle(color: Colors.grey))),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }

  Widget _chips(String label, List<String> values, String kind) {
    if (values.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final v in values)
                ActionChip(
                  label: Text(v),
                  onPressed: () => Navigator.pop(context, (kind, v)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final big = it.fanart.isNotEmpty ? it.fanart : it.poster;
    return Scaffold(
      appBar: AppBar(
        title: Text(it.num.isEmpty ? it.title : it.num),
        actions: [
          IconButton(
            tooltip: libStore.isFav(it) ? '取消收藏' : '收藏',
            icon: Icon(
              libStore.isFav(it) ? Icons.favorite : Icons.favorite_border,
              color: libStore.isFav(it) ? Colors.redAccent : null,
            ),
            onPressed: () => libStore.toggleFav(it),
          ),
          IconButton(
            tooltip: libStore.isSeen(it) ? '标为未看' : '标为已看',
            icon: Icon(
              libStore.isSeen(it)
                  ? Icons.check_circle
                  : Icons.check_circle_outline,
              color: libStore.isSeen(it) ? Colors.green : null,
            ),
            onPressed: () => libStore.setSeen(it, !libStore.isSeen(it)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (big.isNotEmpty)
            SizedBox(
              height: 340,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: _posterImage(big, fit: BoxFit.contain),
              ),
            ),
          const SizedBox(height: 12),
          SelectableText(it.title,
              style: Theme.of(context).textTheme.titleLarge),
          if (it.origTitle.isNotEmpty && it.origTitle != it.title)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(it.origTitle,
                  style: const TextStyle(color: Colors.grey)),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _play,
                icon: const Icon(Icons.play_arrow),
                label: const Text('播放'),
              ),
              OutlinedButton.icon(
                onPressed: _showFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('打开所在文件夹'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, ('rescrape', '')),
                icon: const Icon(Icons.refresh),
                label: const Text('重新刮削'),
              ),
              OutlinedButton.icon(
                onPressed: _editTitle,
                icon: const Icon(Icons.edit),
                label: const Text('修改标题'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _info('番号', it.num),
          _info('发行日期', it.date),
          _info('时长', it.runtime > 0 ? '${it.runtime} 分钟' : ''),
          _info('导演', it.director),
          _chips('演员', it.actors, 'actor'),
          _chips('类别', it.genres, 'genre'),
          _chips('厂商', it.studio.isEmpty ? [] : [it.studio], 'studio'),
          _chips('系列', it.series.isEmpty ? [] : [it.series], 'series'),
          if (it.tags.isNotEmpty) _info('标签', it.tags.join('、')),
          const SizedBox(height: 10),
          _info('文件', it.path),
          if (_stills.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('剧照（${_stills.length}）',
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 6),
            SizedBox(
              height: 150,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: _stills.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => showDialog(
                      context: context,
                      builder: (_) => Dialog(
                        child: InteractiveViewer(
                          child: _posterImage(_stills[i], fit: BoxFit.contain),
                        ),
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _posterImage(_stills[i], cacheWidth: 400),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════ NFO ═══════════════════════

String _x(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String buildNfo(Movie m, [List<String> extraTags = const []]) {
  final year = m.date.length >= 4 ? m.date.substring(0, 4) : '';
  final b = StringBuffer();
  b.writeln('<?xml version="1.0" encoding="utf-8" standalone="yes"?>');
  b.writeln('<movie>');
  b.writeln('  <title>${_x('${m.num} ${m.displayTitle}')}</title>');
  b.writeln('  <originaltitle>${_x(m.title)}</originaltitle>');
  b.writeln('  <sorttitle>${_x(m.num)}</sorttitle>');
  b.writeln('  <num>${_x(m.num)}</num>');
  b.writeln('  <uniqueid type="num" default="true">${_x(m.num)}</uniqueid>');
  if (year.isNotEmpty) {
    b.writeln('  <year>$year</year>');
    b.writeln('  <premiered>${_x(m.date)}</premiered>');
    b.writeln('  <releasedate>${_x(m.date)}</releasedate>');
  }
  if (m.runtime > 0) b.writeln('  <runtime>${m.runtime}</runtime>');
  if (m.studio.isNotEmpty) b.writeln('  <studio>${_x(m.studio)}</studio>');
  if (m.director.isNotEmpty) {
    b.writeln('  <director>${_x(m.director)}</director>');
  }
  if (m.series.isNotEmpty) b.writeln('  <set>${_x(m.series)}</set>');
  for (final g in m.genres) {
    b.writeln('  <genre>${_x(g)}</genre>');
    b.writeln('  <tag>${_x(g)}</tag>');
  }
  for (final t in extraTags) {
    b.writeln('  <tag>${_x(t)}</tag>');
  }
  for (final a in m.actors) {
    b.writeln('  <actor>');
    b.writeln('    <name>${_x(a)}</name>');
    b.writeln('    <type>Actor</type>');
    b.writeln('  </actor>');
  }
  for (final u in m.urls) {
    b.writeln('  <website>${_x(u)}</website>');
  }
  b.writeln('</movie>');
  return b.toString();
}

// ═══════════════════════ 界面 ═══════════════════════

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final s = Cfg();
  final _javbusCtl = TextEditingController();
  final _javdbCtl = TextEditingController();
  final _proxyCtl = TextEditingController();
  final _subCtl = TextEditingController();
  final _smbHostCtl = TextEditingController();
  final _smbUserCtl = TextEditingController();
  final _smbPassCtl = TextEditingController();
  final _smbDomainCtl = TextEditingController();
  final _tplCtl = TextEditingController();
  final _logs = <String>[];
  final _scroll = ScrollController();
  bool _running = false;
  bool _cancel = false;
  int _done = 0;
  int _total = 0;
  final _failed = <_Fail>[];
  String _failKind = 'local';
  String _failReason = '';
  Map<String, dynamic>? _batch;
  int _undoCount = 0;
  final _cache = <String, Movie>{};
  final _coverCache = <String, Uint8List>{};
  int _tab = 0; // 电脑版：0=刮削 1=影视库
  String? _rootOverride; // 影视库补刮时，整理的根文件夹
  bool _recOn = true; // 是否记录生成的文件（影视库补刮时不记录）
  String? _selDir; // 已选择的影片文件夹
  String _selKind = 'local';
  List<String> _files = []; // 已选文件夹里的视频
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _applyCtl();
    _loadCfg();
    _loadJournalInfo();
  }

  @override
  void dispose() {
    _javbusCtl.dispose();
    _javdbCtl.dispose();
    _proxyCtl.dispose();
    _subCtl.dispose();
    _smbHostCtl.dispose();
    _smbUserCtl.dispose();
    _smbPassCtl.dispose();
    _smbDomainCtl.dispose();
    _tplCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _applyCtl() {
    _javbusCtl.text = s.javbusUrl;
    _javdbCtl.text = s.javdbUrl;
    _proxyCtl.text = s.proxy;
    _subCtl.text = s.subUrl;
    _smbHostCtl.text = s.smbHost;
    _smbUserCtl.text = s.smbUser;
    _smbPassCtl.text = s.smbPass;
    _smbDomainCtl.text = s.smbDomain;
    _tplCtl.text = s.folderTpl;
  }

  Future<void> _loadCfg() async {
    try {
      final f = File(_cfgPath);
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        s.load(j);
        if (!Platform.isAndroid) s.source = 'local';
        themeNotifier.value = themeFromString(s.themeMode);
        _applyCtl();
      });
    } catch (_) {}
  }

  void _syncCfg() {
    s.javbusUrl = _javbusCtl.text.trim();
    s.javdbUrl = _javdbCtl.text.trim();
    s.proxy = _proxyCtl.text.trim();
    s.subUrl = _subCtl.text.trim();
    s.smbHost = _smbHostCtl.text.trim();
    s.smbUser = _smbUserCtl.text.trim();
    s.smbPass = _smbPassCtl.text;
    s.smbDomain = _smbDomainCtl.text.trim();
    s.folderTpl = _tplCtl.text.trim().isEmpty ? '{番号}' : _tplCtl.text.trim();
    if (!Platform.isAndroid) s.source = 'local';
  }

  Future<void> _saveCfg() async {
    try {
      final f = File(_cfgPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(s.toJson()));
    } catch (_) {}
  }

  void _log(String t) {
    if (!mounted) return;
    setState(() => _logs.add(t));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    var st = await Permission.manageExternalStorage.request();
    if (st.isGranted) return true;
    st = await Permission.storage.request();
    return st.isGranted;
  }

  Future<Partial?> _safe(String name, Future<Partial?> Function() f) async {
    try {
      final r = await f();
      if (r == null) _log('   · $name：没有这个番号');
      return r;
    } catch (e) {
      _log('   · $name：失败 ${errText(e)}');
      return null;
    }
  }

  /// kind: local=本机存储  smb=网络共享
  Future<Fs> _openFs(String kind) async {
    if (kind != 'smb') return LocalFs();
    final c = await smb.SmbConnect.connectAuth(
      host: s.smbHost,
      domain: s.smbDomain,
      username: s.smbUser,
      password: s.smbPass,
    ).timeout(const Duration(seconds: 20));
    return SmbFs(c);
  }

  Future<void> _loadJournalInfo() async {
    final all = await loadJournal();
    if (mounted) setState(() => _undoCount = all.length);
  }

  Map<String, dynamic> _newBatch(String label, String kind) => {
        'id': DateTime.now().toIso8601String(),
        'label': label,
        'fs': kind,
        'moves': [],
        'created': [],
        'dirs': [],
      };

  /// 记录本次生成的文件（撤销时会删除）
  void _rec(String path) {
    if (!_recOn) return;
    final c = _batch?['created'];
    if (c is List) c.add(path);
  }

  Future<void> _commitBatch() async {
    final b = _batch;
    if (b == null) return;
    final has =
        (b['moves'] as List).isNotEmpty || (b['created'] as List).isNotEmpty;
    final all = await loadJournal();
    all.removeWhere((e) => e['id'] == b['id']);
    if (has) all.add(b);
    await saveJournal(all);
    if (mounted) setState(() => _undoCount = all.length);
  }

  Future<void> _translateMovie(Net net, Movie m) async {
    if (m.translated) return;
    m.translated = true;
    if (m.title.isNotEmpty) {
      final t = await translateText(net, m.title, s.trLang,
          from: 'ja', log: _log);
      if (t != null) m.titleZh = t;
    }
    if (m.genres.isNotEmpty) {
      final g = await translateList(net, m.genres, s.trLang, log: _log);
      if (g != null) m.genres = g;
    }
  }

  /// 计算整理后的目标文件夹
  String _destDir(List<String> parts, String vpath) {
    final cur = p.dirname(vpath);
    final root = _rootOverride ??
        ((_selDir != null && _selKind == _failKind) ? _selDir : null);
    if (s.organizeBase == 'root' && root != null) {
      return p.joinAll([root, ...parts]);
    }
    if (_tailMatches(cur, parts)) return cur; // 已经在对应文件夹里，不再套一层
    return p.joinAll([cur, ...parts]);
  }

  /// 设置里显示的模板示例
  String _tplExample() {
    final m = Movie('SSIS-123')
      ..title = '示例标题'
      ..date = '2021-05-01'
      ..studio = '示例厂商'
      ..series = '示例系列'
      ..director = '示例导演'
      ..actors = ['示例演员'];
    final tpl = _tplCtl.text.trim().isEmpty ? '{番号}' : _tplCtl.text.trim();
    return folderPartsFor(m, tpl, 'SSIS-123').join('/');
  }

  List<DiagCheck> _buildChecks() {
    final checks = <DiagCheck>[];
    final px = s.proxy.trim();
    if (px.isNotEmpty) {
      checks.add(DiagCheck('代理 $px', (net) async {
        final hp = px
            .replaceFirst(RegExp(r'^[a-zA-Z]+://'), '')
            .replaceAll(RegExp(r'/+$'), '');
        final i = hp.lastIndexOf(':');
        if (i <= 0) return (false, '格式不对，应该是 地址:端口');
        final port = int.tryParse(hp.substring(i + 1));
        if (port == null) return (false, '端口不是数字');
        final sock = await Socket.connect(hp.substring(0, i), port,
            timeout: const Duration(seconds: 4));
        sock.destroy();
        return (true, '代理端口可以连接');
      }));
    }
    if (s.useJavbus) {
      checks.add(DiagCheck(
          'JavBus', (net) => pageCheck(net, s.javbusUrl, extra: {
                'Cookie': 'existmag=all; age=verified; dv=1',
              })));
    }
    if (s.useJavdb) {
      checks.add(DiagCheck(
          'JavDB',
          (net) => pageCheck(net, s.javdbUrl,
              extra: {'Cookie': 'over18=1; locale=zh'})));
    }
    if (s.useDmm || s.downloadCover) {
      checks.add(DiagCheck('DMM 封面图床', (net) async {
        final r = await net.get(
            'https://awsimgsrc.dmm.co.jp/pics_dig/digital/video/ssis00001/ssis00001pl.jpg');
        if (r.statusCode == 200) return (true, '可以访问，图片正常');
        if (r.statusCode == 404) return (true, '服务器可以访问（测试图片不存在，不影响使用）');
        return (false, 'HTTP ${r.statusCode}');
      }));
    }
    if (s.translate) {
      checks.add(DiagCheck('翻译（谷歌）', (net) async {
        final t = await _googleTr(net, 'こんにちは', s.trLang, 'ja');
        if (t == null || t.trim().isEmpty) return (false, '没有返回结果');
        return (true, '翻译正常：こんにちは → ${t.trim()}');
      }));
    }
    if (s.downloadSub) {
      checks.add(DiagCheck('字幕站', (net) => pageCheck(net, s.subUrl)));
    }
    if (Platform.isAndroid && s.smbHost.isNotEmpty) {
      checks.add(DiagCheck('网络共享 ${s.smbHost}', (net) async {
        final fs = await _openFs('smb');
        try {
          final shares = await fs.list('/');
          return (true, '连接成功，找到 ${shares.length} 个共享');
        } finally {
          await fs.close();
        }
      }));
    }
    return checks;
  }

  void _openDiag() {
    _syncCfg();
    final checks = _buildChecks();
    showDialog(
      context: context,
      builder: (_) => DiagDialog(checks: checks, proxy: s.proxy),
    );
  }

  /// 影视库里的「补刮 / 重新刮削」：对选中的影片重新刮削（覆盖已有 NFO 和封面）
  Future<void> _rescrapeLibrary(List<LibItem> list) async {
    if (_running || _scanning || list.isEmpty) return;
    _syncCfg();
    setState(() {
      _tab = 0; // 切到刮削页面，方便看进度
      _running = true;
      _cancel = false;
      _done = 0;
      _total = list.length;
      _logs.clear();
      _failed.clear();
    });
    _log('影片刮削器 v$appVersion');
    _log('📚 从影视库重新刮削 ${list.length} 部影片（会覆盖已有 NFO 和封面）');

    final fsys = LocalFs();
    _failKind = 'local';
    _cache.clear();
    _coverCache.clear();
    _batch = _newBatch(
        '影视库补刮 ${DateTime.now().toString().substring(0, 16)}', 'local');
    _recOn = false; // 覆盖了原有文件，撤销时不要删除它们
    final net = Net(s.proxy);
    var ok = 0, fail = 0;
    try {
      for (final it in list) {
        if (_cancel) {
          _log('⏹ 已停止');
          break;
        }
        _rootOverride = libStore.folders.firstWhere(
            (f) => p.equals(f, it.dir) || p.isWithin(f, it.path),
            orElse: () => it.dir);
        var code = 2;
        _failReason = '';
        try {
          code = await _processOne(net, fsys, it.path,
              forceNum: it.num.isNotEmpty ? it.num : null, overwrite: true);
        } catch (e) {
          _failReason = errText(e);
          _log('❌ 出错：$_failReason');
        }
        if (code == 0) {
          ok++;
        } else {
          fail++;
          _failed.add(_Fail(it.path, _failReason.isEmpty ? '失败' : _failReason));
        }
        if (_batch != null && code == 0) await _commitBatch();
        if (mounted) setState(() => _done++);
        await Future.delayed(const Duration(milliseconds: 1500));
      }
    } finally {
      net.close();
      _rootOverride = null;
      _recOn = true;
    }
    await _commitBatch();
    _batch = null;
    _log('🎉 完成：成功 $ok，失败 $fail'
        '${_failed.isNotEmpty ? '（可点下方按钮手动输入番号重试）' : ''}');
    if (mounted) setState(() => _running = false);
    libStore.rescan();
  }

  /// 返回 0=成功 1=跳过 2=失败
  Future<int> _processOne(Net net, Fs fs, String vpath,
      {String? forceNum, bool dry = false, bool overwrite = false}) async {
    final name = p.basename(vpath);
    final stem = p.basenameWithoutExtension(vpath);
    var base = p.withoutExtension(vpath);

    if (s.skipExisting && !overwrite && await fs.exists('$base.nfo')) {
      _log('⏭ 已有 NFO，跳过：$name');
      return 1;
    }
    final num = forceNum ?? extractCode(name);
    if (num == null) {
      _failReason = '未识别番号';
      _log('❓ 未识别番号：$name');
      return 2;
    }
    _log('🔎 $num   ($name)');

    final Movie m;
    final cached = _cache[num];
    if (cached != null) {
      _log('   · 本次已查询过这个番号，直接复用资料');
      m = cached;
    } else {
      final tasks = <Future<Partial?>>[];
      if (s.useJavbus) {
        tasks.add(_safe('JavBus', () => scrapeJavbus(net, s.javbusUrl, num)));
      }
      if (s.useJavdb) {
        tasks.add(_safe('JavDB', () => scrapeJavdb(net, s.javdbUrl, num)));
      }
      final got = (await Future.wait(tasks)).whereType<Partial>().toList();
      if (s.useDmm) got.add(Partial('DMM')..covers = dmmCovers(num));
      if (!got.any((e) => e.hasMeta)) {
        _failReason = '所有来源都没查到';
        _log('   ✖ 所有来源都没查到资料');
        return 2;
      }
      m = mergeAll(num, got);
      _cache[num] = m;
    }
    final tags = codeTags(name);

    if (s.translate) await _translateMovie(net, m);

    // 试运行：只预览，不改动任何文件
    final parts = folderPartsFor(m, s.folderTpl, stem);
    if (dry) {
      final dest = _destDir(parts, vpath);
      final where = !s.organize
          ? '不整理'
          : (p.equals(p.dirname(vpath), dest)
              ? '已在正确的文件夹里'
              : '将移动到 ${parts.join('/')}/');
      final will = [
        'NFO',
        if (s.downloadCover) '封面',
        if (s.downloadStills) '剧照(${m.stills.length})',
        if (s.downloadSub) '字幕',
      ].join('+');
      _log('📋 ${m.displayTitle}\n   来源：${m.sources.join(' + ')}\n'
          '   $where；将生成：$will');
      return 0;
    }

    // 整理：新建文件夹，把视频和同名附属文件移进去
    var organized = '';
    if (s.organize) {
      final destDir = _destDir(parts, vpath);
      try {
        final moved = await organizeInto(fs, vpath, destDir,
            moves: _batch?['moves'] as List?,
            newDirs: _batch?['dirs'] as List?);
        base = p.withoutExtension(moved);
        organized = parts.join('/');
      } catch (e) {
        _log('   ⚠️ 整理失败：${errText(e)}（资料仍保存在原位置）');
      }
    }

    var coverOk = false;
    if (s.downloadCover && m.covers.isNotEmpty) {
      var bytes = _coverCache[num];
      if (bytes == null) {
        final res = await fetchCover(net, m.covers, _log);
        if (res != null) {
          bytes = res.$1;
          if (_coverCache.length >= 20) {
            _coverCache.remove(_coverCache.keys.first);
          }
          _coverCache[num] = bytes;
        }
      }
      if (bytes != null) {
        final poster = await compute(makePoster, bytes);
        await fs.writeBytes('$base-poster.jpg', poster ?? bytes);
        await fs.writeBytes('$base-fanart.jpg', bytes);
        _rec('$base-poster.jpg');
        _rec('$base-fanart.jpg');
        coverOk = true;
      }
    }

    var stillsNote = '';
    if (s.downloadStills) {
      if (m.stills.isEmpty) {
        stillsNote = '剧照：无';
      } else {
        try {
          final parent = p.dirname(base);
          final own = organized.isNotEmpty || _tailMatches(parent, parts);
          final dir = own
              ? p.join(parent, 'extrafanart')
              : p.join(parent, '$stem-extrafanart');
          final existed = await fs.exists(dir);
          final n = await downloadStills(
              net, fs, m.stills, dir, s.stillsMax, _rec);
          if (!existed && n > 0) {
            (_batch?['dirs'] as List?)?.add(dir);
          }
          stillsNote = '剧照：$n 张';
        } catch (e) {
          _log('   · 剧照失败：${errText(e)}');
          stillsNote = '剧照：✗';
        }
      }
    }

    await fs.writeBytes('$base.nfo', utf8.encode(buildNfo(m, tags)));
    _rec('$base.nfo');

    var subNote = '';
    if (s.downloadSub) {
      if (await hasSubtitle(fs, base)) {
        subNote = '字幕：已有';
      } else {
        try {
          final sub = await fetchSubtitle(net, s.subUrl, num, _log);
          if (sub != null) {
            await fs.writeBytes('$base.${sub.$2}.srt', sub.$1);
            _rec('$base.${sub.$2}.srt');
            subNote = '字幕：✓';
          } else {
            subNote = '字幕：✗';
          }
        } catch (e) {
          _log('   · 字幕：失败 ${errText(e)}');
          subNote = '字幕：✗';
        }
      }
    }

    final tail = [
      '来源：${m.sources.join(' + ')}',
      '封面：${s.downloadCover ? (coverOk ? '✓' : '✗') : '未开启'}',
      if (stillsNote.isNotEmpty) stillsNote,
      if (s.translate) '翻译：${m.titleZh.isNotEmpty ? '✓' : '✗'}',
      if (organized.isNotEmpty) '📁 $organized/',
      if (subNote.isNotEmpty) subNote,
      if (tags.isNotEmpty) '🏷 ${tags.join('/')}',
    ].join('   ');
    final orig = (m.titleZh.isNotEmpty && m.titleZh != m.title)
        ? '\n   原题：${m.title}'
        : '';
    _log('✅ ${m.displayTitle}$orig\n   $tail');
    return 0;
  }

  /// 只下载字幕（不刮削、不移动文件）。返回 0=成功 1=跳过 2=失败
  Future<int> _subOne(Net net, Fs fs, String vpath) async {
    final name = p.basename(vpath);
    final base = p.withoutExtension(vpath);
    if (await hasSubtitle(fs, base)) {
      _log('⏭ 已有字幕，跳过：$name');
      return 1;
    }
    final num = extractCode(name);
    if (num == null) {
      _failReason = '未识别番号';
      _log('❓ 未识别番号：$name');
      return 2;
    }
    _log('🔎 $num   ($name)');
    try {
      final sub = await fetchSubtitle(net, s.subUrl, num, _log);
      if (sub == null) {
        _failReason = '没有中文字幕';
        _log('   ✖ 没有找到中文字幕');
        return 2;
      }
      final out = '$base.${sub.$2}.srt';
      await fs.writeBytes(out, sub.$1);
      _log('✅ 字幕已保存：${p.basename(out)}');
      return 0;
    } catch (e) {
      _failReason = errText(e);
      _log('   ✖ 字幕失败：$_failReason');
      return 2;
    }
  }

  /// 第一步：选择影片文件夹，并扫描里面的视频
  Future<void> _pickFolder() async {
    if (_running || _scanning) return;
    _syncCfg();
    final kind = s.source;
    final granted = await _ensurePermission();
    if (kind == 'local' && !granted) {
      _log('❌ 没有获得「所有文件访问权限」。请在系统设置里给本应用开启后重试。');
      return;
    }
    await _saveCfg();
    setState(() => _scanning = true);

    Fs? fs;
    String? dir;
    var files = <String>[];
    try {
      if (kind == 'smb') {
        if (s.smbHost.isEmpty) {
          _log('❌ 请先在设置里填写 SMB 服务器地址、用户名和密码');
        } else {
          _log('🔌 正在连接 ${s.smbHost} …');
          final conn = await _openFs('smb');
          fs = conn;
          if (mounted) {
            dir = await showDialog<String>(
              context: context,
              barrierDismissible: false,
              builder: (_) => RemoteDirPicker(fs: conn, initial: s.smbPath),
            );
          }
          if (dir != null) {
            s.smbPath = dir;
            await _saveCfg();
          }
        }
      } else {
        fs = LocalFs();
        dir = await FilePicker.platform
            .getDirectoryPath(dialogTitle: '选择存放影片的文件夹');
      }
      if (dir != null && fs != null) {
        if (mounted) setState(() => _logs.clear());
        _log('📂 正在扫描：$dir');
        files = await scanVideos(fs, dir);
      }
    } catch (e) {
      _log('❌ ${kind == 'smb' ? '连接失败' : '出错'}：${errText(e)}');
      dir = null;
    } finally {
      await fs?.close();
    }
    if (!mounted) return;
    setState(() {
      _scanning = false;
      if (dir != null) {
        _selDir = dir;
        _selKind = kind;
        _files = files;
        _failed.clear();
        _done = 0;
        _total = 0;
      }
    });
    if (dir != null) {
      _log(files.isEmpty
          ? '已选择：$dir\n这个文件夹里没有找到视频文件'
          : '已选择：$dir\n找到 ${files.length} 个视频文件，请在下方选择要执行的操作');
    }
  }

  /// 重新扫描已选文件夹（文件被整理或移动后，列表会随之更新）
  Future<void> _rescan() async {
    final root = _selDir;
    if (root == null || _running || _scanning) return;
    _syncCfg();
    setState(() => _scanning = true);
    Fs? fs;
    try {
      fs = await _openFs(_selKind);
      final fresh = await scanVideos(fs, root);
      if (mounted) setState(() => _files = fresh);
    } catch (e) {
      _log('❌ 重新扫描失败：${errText(e)}');
    } finally {
      await fs?.close();
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// 第二步：对已选择的文件夹执行操作（刮削 / 试运行 / 只下载字幕）
  Future<void> _run({bool subsOnly = false, bool dry = false}) async {
    final root = _selDir;
    if (_running || _scanning || root == null) return;
    _syncCfg();
    final kind = _selKind;
    await _saveCfg();

    setState(() {
      _running = true;
      _cancel = false;
      _done = 0;
      _total = 0;
      _logs.clear();
      _failed.clear();
    });
    _log('影片刮削器 v$appVersion');

    final Fs fsys;
    try {
      if (kind == 'smb') _log('🔌 正在连接 ${s.smbHost} …');
      fsys = await _openFs(kind);
    } catch (e) {
      _log('❌ 连接失败：${errText(e)}');
      if (mounted) setState(() => _running = false);
      return;
    }

    _failKind = kind;
    _cache.clear();
    _coverCache.clear();
    _batch = (subsOnly || dry)
        ? null
        : _newBatch(
            '${DateTime.now().toString().substring(0, 16)}  ${p.basename(root)}',
            kind);

    _log('📂 $root'
        '${subsOnly ? '（只下载字幕）' : dry ? '（试运行，不会改动任何文件）' : ''}');
    if (Platform.isAndroid && s.keepAwake) keepAwake(true);

    final files = List<String>.of(_files);
    if (mounted) setState(() => _total = files.length);
    _log('共 ${files.length} 个视频文件');

    final net = Net(s.proxy);
    var ok = 0, skip = 0, fail = 0;
    try {
      for (final path in files) {
        if (_cancel) {
          _log('⏹ 已停止');
          break;
        }
        var code = 2;
        _failReason = '';
        try {
          code = subsOnly
              ? await _subOne(net, fsys, path)
              : await _processOne(net, fsys, path, dry: dry);
        } catch (e) {
          _failReason = errText(e);
          _log('❌ 出错：$_failReason');
        }
        if (code == 0) ok++;
        if (code == 1) skip++;
        if (code == 2) {
          fail++;
          if (!subsOnly && !dry) {
            _failed.add(_Fail(path, _failReason.isEmpty ? '失败' : _failReason));
          }
        }
        if (_batch != null && code == 0) await _commitBatch();
        if (mounted) setState(() => _done++);
        if (code != 1) await Future.delayed(const Duration(milliseconds: 1500));
      }
    } finally {
      net.close();
      keepAwake(false);
    }
    await _commitBatch();
    _batch = null;

    // 整理后文件位置会变，重新扫描一遍，保证下次操作的列表是最新的
    var fresh = files;
    if (!dry && !subsOnly) {
      try {
        fresh = await scanVideos(fsys, root);
      } catch (_) {}
    }
    await fsys.close();

    if (!Platform.isAndroid &&
        s.autoLibrary &&
        !dry &&
        !subsOnly &&
        kind == 'local' &&
        ok > 0) {
      final added = await libStore.addFolder(root);
      libStore.rescan();
      if (added) _log('📚 已把这个文件夹加入影视库');
    }

    _log('${dry ? '📋 试运行结束' : '🎉 完成'}：'
        '成功 $ok，跳过 $skip，失败/未识别 $fail'
        '${_failed.isNotEmpty ? '（可点下方按钮手动输入番号重试）' : ''}');
    if (mounted) {
      setState(() {
        _files = fresh;
        _running = false;
      });
    }
  }

  /// 撤销上一次整理：文件移回原位，删除那次生成的 NFO/封面/剧照/字幕
  Future<void> _undoLast() async {
    if (_running) return;
    final all = await loadJournal();
    if (all.isEmpty) {
      _log('没有可撤销的整理记录');
      if (mounted) setState(() => _undoCount = 0);
      return;
    }
    final b = all.last;
    final kind = (b['fs'] as String?) ?? 'local';
    final moves = (b['moves'] as List)
        .map((e) => (e as List).cast<String>())
        .toList();
    final created = (b['created'] as List).cast<String>();
    final dirs = (b['dirs'] as List).cast<String>();
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销上次整理？'),
        content: Text('${b['label']}'
            '${kind == 'smb' ? '（网络共享）' : ''}\n\n'
            '将把 ${moves.length} 个文件移回原来的位置，'
            '并删除这次生成的 ${created.length} 个 NFO / 封面 / 剧照 / 字幕文件。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('撤销')),
        ],
      ),
    );
    if (yes != true) return;

    _syncCfg();
    setState(() => _running = true);
    _log('↩ 开始撤销：${b['label']}');
    Fs? fs;
    try {
      fs = await _openFs(kind);
      final f = fs;
      for (final c in created) {
        try {
          if (await f.exists(c)) await f.delete(c);
        } catch (_) {}
      }
      var back = 0, miss = 0;
      for (final mv in moves.reversed) {
        final from = mv[0], to = mv[1];
        try {
          if (!await f.exists(to) || await f.exists(from)) {
            miss++;
            continue;
          }
          await f.mkdirs(p.dirname(from));
          await f.move(to, from);
          back++;
        } catch (e) {
          miss++;
          _log('   ⚠️ ${p.basename(to)} 无法移回：${errText(e)}');
        }
      }
      for (final d in dirs.reversed) {
        try {
          if (await f.exists(d) && (await f.list(d)).isEmpty) {
            await f.delete(d);
          }
        } catch (_) {}
      }
      all.removeLast();
      await saveJournal(all);
      if (_selDir != null && _selKind == kind) {
        try {
          final fresh = await scanVideos(f, _selDir!);
          if (mounted) setState(() => _files = fresh);
        } catch (_) {}
      }
      _log('↩ 已撤销：移回 $back 个文件'
          '${miss > 0 ? '，$miss 个没法移回（已不在原处，或原位置已有同名文件）' : ''}');
      if (mounted) setState(() => _undoCount = all.length);
    } catch (e) {
      _log('❌ 撤销失败：${errText(e)}');
    } finally {
      await fs?.close();
      if (mounted) setState(() => _running = false);
    }
  }

  /// 对失败的单个文件，手动指定番号后重试
  Future<void> _retryOne(_Fail f, String input) async {
    if (_running) return;
    final num = extractCode(input) ?? input.trim().toUpperCase();
    if (num.isEmpty) return;
    _syncCfg();
    setState(() {
      _running = true;
      _cancel = false;
    });
    _batch = _newBatch('手动处理 ${p.basename(f.path)}', _failKind);
    Fs? fs;
    final net = Net(s.proxy);
    var code = 2;
    try {
      fs = await _openFs(_failKind);
      code = await _processOne(net, fs, f.path, forceNum: num, overwrite: true);
      if (code == 0 && _selDir != null && _selKind == _failKind) {
        try {
          final fresh = await scanVideos(fs, _selDir!);
          if (mounted) setState(() => _files = fresh);
        } catch (_) {}
      }
    } catch (e) {
      _log('❌ 出错：${errText(e)}');
    } finally {
      net.close();
      await fs?.close();
    }
    await _commitBatch();
    _batch = null;
    if (mounted) {
      setState(() {
        if (code == 0) _failed.remove(f);
        _running = false;
      });
    }
  }

  Future<String?> _askNum(BuildContext ctx, _Fail f) {
    final c = TextEditingController(text: extractCode(p.basename(f.path)) ?? '');
    return showDialog<String>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('输入番号'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            hintText: '例如 MVSD-696',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(dctx, c.text),
              child: const Text('开始刮削')),
        ],
      ),
    );
  }

  void _openFailed() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('点一下文件，手动输入番号后重试')),
            for (final f in _failed)
              ListTile(
                title: Text(p.basename(f.path),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(f.reason),
                trailing: const Icon(Icons.edit),
                onTap: () async {
                  final text = await _askNum(ctx, f);
                  if (text == null || text.trim().isEmpty) return;
                  if (ctx.mounted) Navigator.pop(ctx);
                  _retryOne(f, text);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _field(TextEditingController c, String label,
          {bool secret = false, ValueChanged<String>? onChanged}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          obscureText: secret,
          onChanged: onChanged,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _openDiag,
                    icon: const Icon(Icons.network_check),
                    label: const Text('测试连接'),
                  ),
                ),
                _title('外观'),
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                        value: ThemeMode.system, label: Text('跟随系统')),
                    ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('夜间')),
                  ],
                  selected: {themeNotifier.value},
                  onSelectionChanged: (v) {
                    setM(() {
                      themeNotifier.value = v.first;
                      s.themeMode = themeToString(v.first);
                    });
                    _syncCfg();
                    _saveCfg();
                  },
                ),
                _title('刮削源（可多选，结果会合并）'),
                Wrap(
                  spacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('JavBus'),
                      selected: s.useJavbus,
                      onSelected: (v) => setM(() => s.useJavbus = v),
                    ),
                    FilterChip(
                      label: const Text('JavDB'),
                      selected: s.useJavdb,
                      onSelected: (v) => setM(() => s.useJavdb = v),
                    ),
                    FilterChip(
                      label: const Text('DMM 封面'),
                      selected: s.useDmm,
                      onSelected: (v) => setM(() => s.useDmm = v),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _field(_javbusCtl, 'JavBus 网址（可换镜像）'),
                _field(_javdbCtl, 'JavDB 网址'),
                _field(_proxyCtl, 'HTTP 代理（可留空），如 127.0.0.1:7890'),
                if (Platform.isAndroid) ...[
                _title('网络共享（SMB）：NAS / 电脑共享文件夹'),
                const Text(
                  '在主界面选择「网络共享」后，就能直接刮削 NAS 或电脑共享出来的视频。'
                  '支持 SMB1 / SMB2.0 / SMB2.1。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                _field(_smbHostCtl, '服务器地址，如 192.168.1.100'),
                _field(_smbUserCtl, '用户名（匿名共享可填 guest）'),
                _field(_smbPassCtl, '密码', secret: true),
                _field(_smbDomainCtl, '域 / 工作组（一般留空）'),
                ],
                _title('整理'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('刮削成功后整理到文件夹'),
                  subtitle: const Text('新建文件夹，把视频和资料一起移进去'),
                  value: s.organize,
                  onChanged: (v) => setM(() => s.organize = v),
                ),
                if (s.organize) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final pr in const [
                        ['番号', '{番号}'],
                        ['番号+标题', '{番号} {标题}'],
                        ['原文件名', '{原文件名}'],
                        ['演员/番号', '{演员}/{番号}'],
                        ['演员/番号+标题', '{演员}/{番号} {标题}'],
                      ])
                        ChoiceChip(
                          label: Text(pr[0]),
                          selected: _tplCtl.text.trim() == pr[1],
                          onSelected: (_) => setM(() => _tplCtl.text = pr[1]),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _field(_tplCtl, '文件夹命名模板', onChanged: (_) => setM(() {})),
                  Text(
                    '可用：{番号} {标题} {原标题} {演员} {年份} {日期} {厂商} {系列} {导演} {原文件名}\n'
                    '用 / 表示多层文件夹，例如 {演员}/{番号}（按演员分类）。'
                    '演员超过 3 位归入「多人作品」。\n'
                    '示例结果：${_tplExample()}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('整理在视频所在文件夹'),
                        selected: s.organizeBase != 'root',
                        onSelected: (_) =>
                            setM(() => s.organizeBase = 'here'),
                      ),
                      ChoiceChip(
                        label: const Text('整理到所选根文件夹'),
                        selected: s.organizeBase == 'root',
                        onSelected: (_) =>
                            setM(() => s.organizeBase = 'root'),
                      ),
                    ],
                  ),
                  const Text(
                    '按演员分类时建议选「所选根文件夹」，不同子文件夹里的影片会统一归到一起。',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('已有 NFO 的视频跳过'),
                  value: s.skipExisting,
                  onChanged: (v) => setM(() => s.skipExisting = v),
                ),
                if (!Platform.isAndroid)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('刮削后自动加入影视库'),
                  subtitle: const Text('刮削成功后，把这个文件夹加入影视库并刷新'),
                  value: s.autoLibrary,
                  onChanged: (v) => setM(() => s.autoLibrary = v),
                ),
                if (Platform.isAndroid)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('处理时保持屏幕常亮'),
                  subtitle: const Text('批量处理时防止息屏后被系统中断'),
                  value: s.keepAwake,
                  onChanged: (v) => setM(() => s.keepAwake = v),
                ),
                _title('图片'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('下载封面'),
                  value: s.downloadCover,
                  onChanged: (v) => setM(() => s.downloadCover = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('下载剧照'),
                  subtitle: const Text('保存到 extrafanart 文件夹，Emby / Kodi 可当背景'),
                  value: s.downloadStills,
                  onChanged: (v) => setM(() => s.downloadStills = v),
                ),
                if (s.downloadStills)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final n in const [5, 10, 20, 0])
                        ChoiceChip(
                          label: Text(n == 0 ? '全部' : '最多 $n 张'),
                          selected: s.stillsMax == n,
                          onSelected: (_) => setM(() => s.stillsMax = n),
                        ),
                    ],
                  ),
                _title('翻译'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('翻译标题和类别'),
                  subtitle: const Text('原标题保留在 NFO 的 originaltitle 里；需要能访问谷歌翻译，可配合代理'),
                  value: s.translate,
                  onChanged: (v) => setM(() => s.translate = v),
                ),
                if (s.translate)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final l in const [
                        ['zh-CN', '简体中文'],
                        ['zh-TW', '繁體中文'],
                        ['en', 'English'],
                      ])
                        ChoiceChip(
                          label: Text(l[1]),
                          selected: s.trLang == l[0],
                          onSelected: (_) => setM(() => s.trLang = l[0]),
                        ),
                    ],
                  ),
                _title('字幕（实验性）'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('刮削时自动下载中文字幕'),
                  value: s.downloadSub,
                  onChanged: (v) => setM(() => s.downloadSub = v),
                ),
                _field(_subCtl, '字幕站网址'),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      _syncCfg();
      _saveCfg();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) return _buildScrape(context);
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.auto_fix_high),
                label: Text('刮削'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.video_library),
                label: Text('影视库'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _buildScrape(context),
                LibraryPage(onRescrape: _rescrapeLibrary),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScrape(BuildContext context) {
    final busy = _running || _scanning;
    final canRun = !busy && _selDir != null && _files.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('影片刮削器 v$appVersion'),
        actions: [
          IconButton(
            tooltip: '测试连接',
            icon: const Icon(Icons.network_check),
            onPressed: busy ? null : _openDiag,
          ),
          IconButton(
            tooltip: '撤销上次整理',
            icon: const Icon(Icons.undo),
            onPressed: (busy || _undoCount == 0) ? null : _undoLast,
          ),
          IconButton(
            tooltip: '复制日志',
            icon: const Icon(Icons.copy),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _logs.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('日志已复制')),
              );
            },
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings),
            onPressed: busy ? null : _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (Platform.isAndroid)
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: 'local',
                    label: Text('本机存储'),
                    icon: Icon(Icons.phone_android),
                  ),
                  ButtonSegment(
                    value: 'smb',
                    label: Text('网络共享'),
                    icon: Icon(Icons.dns),
                  ),
                ],
                selected: {s.source},
                onSelectionChanged: busy
                    ? null
                    : (v) {
                        setState(() {
                          s.source = v.first;
                          // 换了来源，之前选的文件夹就不适用了
                          if (_selDir != null && _selKind != s.source) {
                            _selDir = null;
                            _files = [];
                            _failed.clear();
                          }
                        });
                        _saveCfg();
                      },
              ),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.folder_open),
                title: Text(
                  _selDir ?? '① 选择影片文件夹',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(_scanning
                    ? '正在扫描…'
                    : _selDir == null
                        ? '先选文件夹，再选择下面的操作'
                        : (_files.isEmpty
                            ? '没有找到视频文件，点这里重新选择'
                            : '找到 ${_files.length} 个视频　（点这里更换文件夹）')),
                trailing: _selDir == null
                    ? null
                    : IconButton(
                        tooltip: '重新扫描',
                        icon: const Icon(Icons.refresh),
                        onPressed: busy ? null : _rescan,
                      ),
                onTap: busy ? null : _pickFolder,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canRun ? () => _run() : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(_running ? '处理中…' : '② 开始刮削'),
                  ),
                ),
                if (_running) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => setState(() => _cancel = true),
                    child: const Text('停止'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canRun ? () => _run(dry: true) : null,
                    icon: const Icon(Icons.visibility),
                    label: const Text('试运行预览'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: canRun ? () => _run(subsOnly: true) : null,
                    icon: const Icon(Icons.subtitles),
                    label: const Text('只下载字幕'),
                  ),
                ),
              ],
            ),
            if (_failed.isNotEmpty && !busy)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openFailed,
                    icon: const Icon(Icons.edit_note),
                    label: Text('手动处理失败的 ${_failed.length} 个'),
                  ),
                ),
              ),
            if (_running || _total > 0) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _total == 0 ? null : _done / _total,
              ),
              const SizedBox(height: 4),
              Text('$_done / $_total'),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: SelectionArea(
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: _logs.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(_logs[i], style: const TextStyle(fontSize: 13)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
