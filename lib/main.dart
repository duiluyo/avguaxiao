import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const ScraperApp());

class ScraperApp extends StatelessWidget {
  const ScraperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '刮削器',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

// ───────────────────────── 数据模型 ─────────────────────────

class MovieInfo {
  final String num;
  String title = '';
  String cover = '';
  String date = '';
  int runtime = 0;
  String studio = '';
  String director = '';
  String series = '';
  List<String> genres = [];
  List<String> actors = [];
  MovieInfo(this.num);
}

// ───────────────────────── 番号识别 ─────────────────────────

const _videoExts = {
  '.mp4', '.mkv', '.avi', '.wmv', '.mov', '.ts', '.m2ts',
  '.flv', '.rmvb', '.mpg', '.webm',
};

// 容易被误识别成番号的常见编码/清晰度字样
const _bannedPrefix = {
  'AVC', 'HEVC', 'AAC', 'FHD', 'UHD', 'WEB', 'BLURAY', 'HDTV', 'DVD',
  'CD', 'PART', 'DISC', 'HD', 'SD', 'DDP', 'DTS', 'EAC', 'AC', 'MP',
};

/// 从文件名里提取番号，例如 "[xxx] ssis00123 1080p.mp4" -> "SSIS-123"
String? extractCode(String filename) {
  final base = p.basenameWithoutExtension(filename);
  final re = RegExp(r'(?<![A-Za-z0-9])([A-Za-z]{2,6})[-_ ]?(\d{2,5})(?!\d)');
  for (final m in re.allMatches(base)) {
    final letters = m.group(1)!.toUpperCase();
    if (_bannedPrefix.contains(letters)) continue;
    final n = int.parse(m.group(2)!);
    final digits = n.toString().padLeft(3, '0');
    return '$letters-$digits';
  }
  return null;
}

// ───────────────────────── 抓取资料 ─────────────────────────

Map<String, String> _headers(String base) => {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Cookie': 'existmag=all; age=verified; dv=1',
      'Referer': base,
    };

Future<MovieInfo?> fetchMovie(String num, String baseUrl) async {
  final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
  final url = Uri.parse('$base/$num');
  final resp = await http
      .get(url, headers: _headers(base))
      .timeout(const Duration(seconds: 20));
  if (resp.statusCode != 200) return null;

  final doc = html_parser
      .parse(utf8.decode(resp.bodyBytes, allowMalformed: true));
  final h3 = doc.querySelector('div.container h3');
  if (h3 == null) return null;

  final info = MovieInfo(num);

  var title = h3.text.trim();
  if (title.toUpperCase().startsWith(num)) {
    title = title.substring(num.length).trim();
  }
  info.title = title;

  final big = doc.querySelector('a.bigImage');
  var cover = big?.attributes['href'] ??
      big?.querySelector('img')?.attributes['src'] ??
      '';
  if (cover.isNotEmpty) cover = url.resolve(cover).toString();
  info.cover = cover;

  final box = doc.querySelector('div.info');
  if (box != null) {
    final text = box.text;
    info.date =
        RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(text)?.group(0) ?? '';
    final rt = RegExp(r'(\d+)\s*(?:分鐘|分钟|min)').firstMatch(text);
    info.runtime = int.tryParse(rt?.group(1) ?? '') ?? 0;

    String first(String key) =>
        box.querySelector('a[href*="/$key/"]')?.text.trim() ?? '';
    info.studio = first('studio');
    info.director = first('director');
    info.series = first('series');

    info.genres = box
        .querySelectorAll('a[href*="/genre/"]')
        .map((e) => e.text.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  info.actors = doc
      .querySelectorAll('div.star-name a')
      .map((e) => (e.attributes['title'] ?? e.text).trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();

  return info;
}

Future<bool> downloadCover(String url, String savePath, String base) async {
  final resp = await http
      .get(Uri.parse(url), headers: _headers(base))
      .timeout(const Duration(seconds: 30));
  if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return false;
  await File(savePath).writeAsBytes(resp.bodyBytes);
  return true;
}

// ───────────────────────── 生成 NFO ─────────────────────────

String _x(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String buildNfo(MovieInfo m) {
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
  b.writeln('</movie>');
  return b.toString();
}

// ───────────────────────── 界面 ─────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _baseCtl = TextEditingController(text: 'https://www.javbus.com');
  final _logs = <String>[];
  final _scroll = ScrollController();
  bool _running = false;
  int _done = 0;
  int _total = 0;

  @override
  void dispose() {
    _baseCtl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _log(String s) {
    if (!mounted) return;
    setState(() => _logs.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    var s = await Permission.manageExternalStorage.request();
    if (s.isGranted) return true;
    s = await Permission.storage.request();
    return s.isGranted;
  }

  Future<void> _start() async {
    if (_running) return;

    if (!await _ensurePermission()) {
      _log('❌ 没有获得「所有文件访问权限」。请在系统设置里给本应用开启后重试。');
      return;
    }

    final dir = await FilePicker.platform
        .getDirectoryPath(dialogTitle: '选择存放视频的文件夹');
    if (dir == null) return;

    setState(() {
      _running = true;
      _done = 0;
      _total = 0;
      _logs.clear();
    });
    _log('📂 扫描：$dir');

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

    final baseUrl = _baseCtl.text.trim();
    var ok = 0, skip = 0, fail = 0;

    for (final file in files) {
      final name = p.basename(file.path);
      final base = p.withoutExtension(file.path);

      if (File('$base.nfo').existsSync()) {
        _log('⏭ 已有 NFO，跳过：$name');
        skip++;
        setState(() => _done++);
        continue;
      }

      final num = extractCode(name);
      if (num == null) {
        _log('❓ 未识别番号：$name');
        fail++;
        setState(() => _done++);
        continue;
      }

      try {
        final info = await fetchMovie(num, baseUrl);
        if (info == null) {
          _log('🔍 没查到 $num：$name');
          fail++;
        } else {
          if (info.cover.isNotEmpty) {
            final saved =
                await downloadCover(info.cover, '$base-poster.jpg', baseUrl);
            if (saved) {
              await File('$base-poster.jpg').copy('$base-fanart.jpg');
            } else {
              _log('⚠️ $num 封面下载失败');
            }
          }
          await File('$base.nfo').writeAsString(buildNfo(info));
          _log('✅ $num ${info.title}');
          ok++;
        }
      } catch (e) {
        _log('❌ $num 出错：$e');
        fail++;
      }

      setState(() => _done++);
      await Future.delayed(const Duration(seconds: 2)); // 礼貌间隔，避免被封
    }

    _log('🎉 完成：成功 $ok，跳过 $skip，失败/未识别 $fail');
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('刮削器')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _baseCtl,
              enabled: !_running,
              decoration: const InputDecoration(
                labelText: '数据源网址',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _running ? null : _start,
                icon: const Icon(Icons.folder_open),
                label: Text(_running ? '刮削中…' : '选择文件夹并开始刮削'),
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
              child: ListView.builder(
                controller: _scroll,
                itemCount: _logs.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(_logs[i], style: const TextStyle(fontSize: 13)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
