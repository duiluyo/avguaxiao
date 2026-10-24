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
const appVersion = '1.4.1';

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

const _cfgPath = '/storage/emulated/0/刮削器/config.json';

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
  }
}

// ═══════════════════════ 网络 ═══════════════════════

const _ua = 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

class Net {
  late final http.Client _client;

  Net(String proxy) {
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
    for (var i = 0; i < 2; i++) {
      try {
        return await _client
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 25));
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

/// mode: num=番号  numTitle=番号+标题  orig=原文件名
String folderNameFor(Movie m, String mode, String origStem) {
  String n;
  switch (mode) {
    case 'numTitle':
      n = '${m.num} ${m.displayTitle}';
      break;
    case 'orig':
      n = origStem;
      break;
    default:
      n = m.num;
  }
  n = safeName(n);
  return n.isEmpty ? m.num : n;
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
    await fs.mkdirs(destDir);
    newDirs?.add(destDir);
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

const _journalPath = '/storage/emulated/0/刮削器/journal.json';

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
          if (name.startsWith('@') || name.startsWith('#') || name.startsWith('.')) {
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
  }

  Future<void> _loadCfg() async {
    try {
      final f = File(_cfgPath);
      if (!f.existsSync()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        s.load(j);
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

  /// 返回 0=成功 1=跳过 2=失败
  Future<int> _processOne(Net net, Fs fs, String vpath,
      {String? forceNum, bool dry = false}) async {
    final name = p.basename(vpath);
    final stem = p.basenameWithoutExtension(vpath);
    var base = p.withoutExtension(vpath);

    if (s.skipExisting && await fs.exists('$base.nfo')) {
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
    if (dry) {
      final folder = folderNameFor(m, s.folderMode, stem);
      final where = !s.organize
          ? '不整理'
          : (p.basename(p.dirname(vpath)) == folder
              ? '已在正确的文件夹里'
              : '将移动到 $folder/');
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
      var destDir = p.dirname(vpath);
      final folder = folderNameFor(m, s.folderMode, stem);
      if (p.basename(destDir) != folder) destDir = p.join(destDir, folder);
      try {
        final moved = await organizeInto(fs, vpath, destDir,
            moves: _batch?['moves'] as List?,
            newDirs: _batch?['dirs'] as List?);
        base = p.withoutExtension(moved);
        organized = folder;
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
          final own =
              organized.isNotEmpty || p.basename(parent) == folderNameFor(m, s.folderMode, stem);
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
    if (s.keepAwake) keepAwake(true);

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
      code = await _processOne(net, fs, f.path, forceNum: num);
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

  Widget _field(TextEditingController c, String label, {bool secret = false}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          obscureText: secret,
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
                _title('整理'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('刮削成功后整理到文件夹'),
                  subtitle: const Text('新建文件夹，把视频和资料一起移进去'),
                  value: s.organize,
                  onChanged: (v) => setM(() => s.organize = v),
                ),
                if (s.organize)
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('文件夹名：番号'),
                        selected: s.folderMode == 'num',
                        onSelected: (_) => setM(() => s.folderMode = 'num'),
                      ),
                      ChoiceChip(
                        label: const Text('番号+标题'),
                        selected: s.folderMode == 'numTitle',
                        onSelected: (_) =>
                            setM(() => s.folderMode = 'numTitle'),
                      ),
                      ChoiceChip(
                        label: const Text('原文件名'),
                        selected: s.folderMode == 'orig',
                        onSelected: (_) => setM(() => s.folderMode = 'orig'),
                      ),
                    ],
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('已有 NFO 的视频跳过'),
                  value: s.skipExisting,
                  onChanged: (v) => setM(() => s.skipExisting = v),
                ),
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
    final busy = _running || _scanning;
    final canRun = !busy && _selDir != null && _files.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: const Text('影片刮削器 v$appVersion'),
        actions: [
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
