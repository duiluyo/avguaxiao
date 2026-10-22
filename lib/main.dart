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
        title: '刮削器',
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

/// "[xxx] ssis00123 1080p.mp4" -> "SSIS-123"
String? extractCode(String filename) {
  final base = p.basenameWithoutExtension(filename);
  final re = RegExp(r'(?<![A-Za-z0-9])([A-Za-z]{2,6})[-_ ]?(\d{2,5})(?!\d)');
  for (final m in re.allMatches(base)) {
    final letters = m.group(1)!.toUpperCase();
    if (_bannedPrefix.contains(letters)) continue;
    final n = int.parse(m.group(2)!);
    return '$letters-${n.toString().padLeft(3, '0')}';
  }
  return null;
}

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
  Movie(this.num);
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
  return jpg || png;
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
      n = '${m.num} ${m.title}';
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
/// 返回视频的新路径
Future<String> organizeInto(File video, String destDir) async {
  final srcDir = video.parent.path;
  if (p.equals(srcDir, destDir)) return video.path;
  await Directory(destDir).create(recursive: true);

  final stem = p.basenameWithoutExtension(video.path);
  final entries = await Directory(srcDir).list().toList();

  final moved = await moveFile(video, p.join(destDir, p.basename(video.path)));

  for (final e in entries) {
    if (e is! File || p.equals(e.path, video.path)) continue;
    final name = p.basename(e.path);
    final isSide = name.startsWith('$stem.') ||
        name == '$stem-poster.jpg' ||
        name == '$stem-fanart.jpg';
    if (!isSide) continue;
    if (!_sidecarExts.contains(p.extension(name).toLowerCase())) continue;
    final target = p.join(destDir, name);
    if (File(target).existsSync()) continue;
    try {
      await moveFile(e, target);
    } catch (_) {}
  }
  return moved.path;
}

// ═══════════════════════ 字幕 ═══════════════════════

const _subExts = {'.srt', '.ass', '.ssa', '.vtt', '.sub'};

/// 视频旁边是否已经有字幕文件
bool hasSubtitle(String base) {
  final stem = p.basename(base);
  try {
    return Directory(p.dirname(base)).listSync().whereType<File>().any((f) {
      final n = p.basename(f.path);
      return n.startsWith('$stem.') &&
          _subExts.contains(p.extension(n).toLowerCase());
    });
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

// ═══════════════════════ NFO ═══════════════════════

String _x(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String buildNfo(Movie m) {
  final year = m.date.length >= 4 ? m.date.substring(0, 4) : '';
  final b = StringBuffer();
  b.writeln('<?xml version="1.0" encoding="utf-8" standalone="yes"?>');
  b.writeln('<movie>');
  b.writeln('  <title>${_x('${m.num} ${m.title}')}</title>');
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
  final _logs = <String>[];
  final _scroll = ScrollController();
  bool _running = false;
  bool _cancel = false;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _javbusCtl.text = s.javbusUrl;
    _javdbCtl.text = s.javdbUrl;
    _proxyCtl.text = s.proxy;
    _subCtl.text = s.subUrl;
    _loadCfg();
  }

  @override
  void dispose() {
    _javbusCtl.dispose();
    _javdbCtl.dispose();
    _proxyCtl.dispose();
    _subCtl.dispose();
    _scroll.dispose();
    super.dispose();
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
        _javbusCtl.text = s.javbusUrl;
        _javdbCtl.text = s.javdbUrl;
        _proxyCtl.text = s.proxy;
        _subCtl.text = s.subUrl;
      });
    } catch (_) {}
  }

  void _syncCfg() {
    s.javbusUrl = _javbusCtl.text.trim();
    s.javdbUrl = _javdbCtl.text.trim();
    s.proxy = _proxyCtl.text.trim();
    s.subUrl = _subCtl.text.trim();
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

  /// 返回 0=成功 1=跳过 2=失败
  Future<int> _processOne(Net net, File file) async {
    final name = p.basename(file.path);
    final stem = p.basenameWithoutExtension(file.path);
    var base = p.withoutExtension(file.path);

    if (s.skipExisting && File('$base.nfo').existsSync()) {
      _log('⏭ 已有 NFO，跳过：$name');
      return 1;
    }
    final num = extractCode(name);
    if (num == null) {
      _log('❓ 未识别番号：$name');
      return 2;
    }
    _log('🔎 $num   ($name)');

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
      _log('   ✖ 所有来源都没查到资料');
      return 2;
    }
    final m = mergeAll(num, got);

    // 整理：新建文件夹，把视频和同名附属文件移进去
    var organized = '';
    if (s.organize) {
      var destDir = file.parent.path;
      final folder = folderNameFor(m, s.folderMode, stem);
      if (p.basename(destDir) != folder) destDir = p.join(destDir, folder);
      try {
        final moved = await organizeInto(file, destDir);
        base = p.withoutExtension(moved);
        organized = folder;
      } catch (e) {
        _log('   ⚠️ 整理失败：${errText(e)}（资料仍保存在原位置）');
      }
    }

    var coverOk = false;
    if (s.downloadCover && m.covers.isNotEmpty) {
      final res = await fetchCover(net, m.covers, _log);
      if (res != null) {
        final bytes = res.$1;
        final poster = await compute(makePoster, bytes);
        await File('$base-poster.jpg').writeAsBytes(poster ?? bytes);
        await File('$base-fanart.jpg').writeAsBytes(bytes);
        coverOk = true;
      }
    }
    await File('$base.nfo').writeAsString(buildNfo(m));

    var subNote = '';
    if (s.downloadSub) {
      if (hasSubtitle(base)) {
        subNote = '字幕：已有';
      } else {
        try {
          final sub = await fetchSubtitle(net, s.subUrl, num, _log);
          if (sub != null) {
            await File('$base.${sub.$2}.srt').writeAsBytes(sub.$1);
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
      if (organized.isNotEmpty) '📁 $organized/',
      if (subNote.isNotEmpty) subNote,
    ].join('   ');
    _log('✅ ${m.title}\n   $tail');
    return 0;
  }

  /// 只下载字幕（不刮削、不移动文件）。返回 0=成功 1=跳过 2=失败
  Future<int> _subOne(Net net, File file) async {
    final name = p.basename(file.path);
    final base = p.withoutExtension(file.path);
    if (hasSubtitle(base)) {
      _log('⏭ 已有字幕，跳过：$name');
      return 1;
    }
    final num = extractCode(name);
    if (num == null) {
      _log('❓ 未识别番号：$name');
      return 2;
    }
    _log('🔎 $num   ($name)');
    try {
      final sub = await fetchSubtitle(net, s.subUrl, num, _log);
      if (sub == null) {
        _log('   ✖ 没有找到中文字幕');
        return 2;
      }
      final out = '$base.${sub.$2}.srt';
      await File(out).writeAsBytes(sub.$1);
      _log('✅ 字幕已保存：${p.basename(out)}');
      return 0;
    } catch (e) {
      _log('   ✖ 字幕失败：${errText(e)}');
      return 2;
    }
  }

  Future<void> _start({bool subsOnly = false}) async {
    if (_running) return;
    if (!await _ensurePermission()) {
      _log('❌ 没有获得「所有文件访问权限」。请在系统设置里给本应用开启后重试。');
      return;
    }
    final dir = await FilePicker.platform
        .getDirectoryPath(dialogTitle: '选择存放视频的文件夹');
    if (dir == null) return;

    _syncCfg();
    await _saveCfg();
    setState(() {
      _running = true;
      _cancel = false;
      _done = 0;
      _total = 0;
      _logs.clear();
    });
    _log('📂 扫描：$dir${subsOnly ? '（只下载字幕）' : ''}');

    final files = <File>[];
    try {
      await for (final e in Directory(dir).list(recursive: true)) {
        if (e is File &&
            _videoExts.contains(p.extension(e.path).toLowerCase())) {
          files.add(e);
        }
      }
    } catch (e) {
      _log('⚠️ 扫描时出错（部分目录可能无法访问）：$e');
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    setState(() => _total = files.length);
    _log('找到 ${files.length} 个视频文件');

    final net = Net(s.proxy);
    var ok = 0, skip = 0, fail = 0;
    try {
      for (final file in files) {
        if (_cancel) {
          _log('⏹ 已停止');
          break;
        }
        var code = 2;
        try {
          code = subsOnly
              ? await _subOne(net, file)
              : await _processOne(net, file);
        } catch (e) {
          _log('❌ 出错：${errText(e)}');
        }
        if (code == 0) ok++;
        if (code == 1) skip++;
        if (code == 2) fail++;
        if (mounted) setState(() => _done++);
        if (code != 1) await Future.delayed(const Duration(milliseconds: 1500));
      }
    } finally {
      net.close();
    }
    _log('🎉 完成：成功 $ok，跳过 $skip，失败/未识别 $fail');
    if (mounted) setState(() => _running = false);
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('外观',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
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
                const SizedBox(height: 16),
                const Text('刮削源（可多选，结果会合并）',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
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
                TextField(
                  controller: _javbusCtl,
                  decoration: const InputDecoration(
                    labelText: 'JavBus 网址（可换镜像）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _javdbCtl,
                  decoration: const InputDecoration(
                    labelText: 'JavDB 网址',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _proxyCtl,
                  decoration: const InputDecoration(
                    labelText: 'HTTP 代理（可留空），如 127.0.0.1:7890',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                const Text('整理',
                    style: TextStyle(fontWeight: FontWeight.bold)),
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
                  title: const Text('下载封面'),
                  value: s.downloadCover,
                  onChanged: (v) => setM(() => s.downloadCover = v),
                ),
                const SizedBox(height: 8),
                const Text('字幕（实验性）',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('刮削时自动下载中文字幕'),
                  value: s.downloadSub,
                  onChanged: (v) => setM(() => s.downloadSub = v),
                ),
                TextField(
                  controller: _subCtl,
                  decoration: const InputDecoration(
                    labelText: '字幕站网址',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('刮削器'),
        actions: [
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
            onPressed: _running ? null : _openSettings,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _running ? null : () => _start(),
                    icon: const Icon(Icons.folder_open),
                    label: Text(_running ? '处理中…' : '选择文件夹并开始刮削'),
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
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: _running ? null : () => _start(subsOnly: true),
                icon: const Icon(Icons.subtitles),
                label: const Text('只下载字幕'),
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
