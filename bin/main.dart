import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

final range_regexp = RegExp(r'^bytes=(\d+)-(\d*)$');
final date_format = DateFormat('y/MM/dd HH:mm:ss');

var home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
var port = 80;
var all_files = false;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', help: '监听端口，默认为 80')
    ..addFlag('all', abbr: 'a', help: '显示所有文件，默认仅显示非隐藏文件', negatable: false)
    ..addFlag('version', abbr: 'v', help: '显示版本信息', negatable: false)
    ..addFlag('help', abbr: 'h', help: '显示此帮助信息', negatable: false);
  ArgResults results;
  try {
    results = parser.parse(args);
  } on ArgParserException {
    stderr.writeln('选项或参数错误');
    return;
  }
  final p = results['port'];
  if (p != null) {
    port = int.tryParse(p);
  }
  all_files = results['all'];
  if (results['version']) {
    stdout.writeln('${Platform.executable} 1.0.0');
    return;
  }
  if (results['help']) {
    stdout
      ..writeln('用法：${Platform.executable} [-p port] [-a] [home]')
      ..writeln()
      ..writeln('选项：')
      ..writeln(parser.usage);
    return;
  }
  if (results.rest.isNotEmpty) {
    home = results.rest[0];
  }
  if (port == null) {
    stderr.writeln('端口错误');
    return;
  }
  if (!FileSystemEntity.isDirectorySync(home)) {
    stderr.writeln('参数错误');
    return;
  }
  await startServer();
}

Future<void> startServer() async {
  final server = await HttpServer.bind('0.0.0.0', port);
  await showTips();
  await for (var req in server) {
    final f = Future(() => handleRequest(req));
  }
}

Future<void> showTips() async {
  log('服务已启动，可使用以下地址访问：');
  final nis = await NetworkInterface.list(type: InternetAddressType.IPv4);
  if (nis.isNotEmpty) {
    for (var ni in nis) {
      printAddress(ni.addresses[0].address);
    }
  } else {
    printAddress('127.0.0.1');
  }
}

void printAddress(String address) {
  if (port != 80) {
    address += ':${port}';
  }
  stdout.writeln('http://${address}');
}

Future<void> handleRequest(HttpRequest req) async {
  final uriPath = Uri.decodeFull(req.uri.path);
  final resp = req.response;
  try {
    final localPath =
        p.join(home, uriPath.startsWith('/') ? uriPath.substring(1) : uriPath);
    final stat = FileStat.statSync(localPath);
    if (req.method != 'GET') {
      resp.statusCode = HttpStatus.methodNotAllowed;
    } else {
      switch (stat.type) {
        case FileSystemEntityType.directory:
          // uriPath 必须以 '/' 结尾，否则输出的 html 中的相对路径无法访问
          if (uriPath.endsWith('/')) {
            await responseDirectory(resp, localPath, uriPath);
          } else {
            await resp.redirect(Uri.parse(uriPath + '/'));
          }
          break;
        case FileSystemEntityType.file:
          await responseFile(resp, localPath, req.headers['Range']);
          break;
        default:
          resp.statusCode = HttpStatus.notFound;
      }
    }
    await resp.flush();
  } finally {
    await resp.close();
  }
  final date = date_format.format(DateTime.now());
  log('[${date}] ${resp.statusCode} ${uriPath}');
}

Future<void> responseDirectory(
    HttpResponse resp, String path, String uriPath) async {
  final dirs = <String>[];
  final files = <String>[];
  // 检查权限
  try {
    await for (var entity in Directory(path).list(followLinks: false)) {
      var basename = p.basename(entity.path);
      if (all_files || !isFileHidden(basename)) {
        final stat = entity.statSync();
        if (stat.type == FileSystemEntityType.directory) {
          dirs.add(basename + '/');
        } else {
          files.add(basename);
        }
      }
    }
  } on FileSystemException {
    resp.statusCode = HttpStatus.unauthorized;
    return;
  }
  dirs.sort(comparePath);
  files.sort(comparePath);
  final title = 'Directory listing for ${uriPath}';
  final pathToHtml = (String path) => '<li><a href="${path}">${path}</a></li>';
  resp.headers.contentType = ContentType.html;
  resp
    ..write('<head>')
    ..write(
        '<meta name="viewport" content="width=device-width,initial-scale=1.0,minimum-scale=1.0"/>')
    ..write('<title>${title}</title>')
    ..write(
        '<style type="text/css">a{text-decoration:none} a:hover{text-decoration:underline}</style>')
    ..write('</head>')
    ..write('<h2>${title}</h2>')
    ..write('<hr>')
    ..write('<ul>')
    ..writeAll(dirs.map<String>(pathToHtml))
    ..writeAll(files.map<String>(pathToHtml))
    ..write('</ul>');
}

Future<void> responseFile(
    HttpResponse resp, String path, List<String> ranges) async {
  final filename = Uri.encodeComponent(p.basename(path));
  final f = File(path);
  final len = f.lengthSync();
  var start = 0;
  var end = len - 1;
  if (ranges != null) {
    if (ranges.length != 1) {
      resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    final match = range_regexp.firstMatch(ranges[0]);
    if (match == null) {
      resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    start = int.parse(match.group(1));
    final endGroup = match.group(2);
    if (endGroup != null && endGroup.isNotEmpty) {
      end = int.parse(endGroup);
    }
    // 容错处理
    if (end >= len) {
      end = len - 1;
    }
    if (start > end) {
      resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    resp.statusCode = HttpStatus.partialContent;
  }
  // 检查权限
  try {
    final fs = await f.openRead(0, 1);
    await fs.isEmpty;
  } on FileSystemException {
    resp.statusCode = HttpStatus.unauthorized;
    return;
  }
  resp.headers
    ..contentType = ContentType.binary
    ..contentLength = end - start + 1
    ..add(HttpHeaders.acceptRangesHeader, 'bytes')
    ..add(HttpHeaders.contentRangeHeader, 'bytes ${start}-${end}/${len}')
    ..add('Content-Disposition',
        'attachment;filename="${filename}";filename*="utf-8\'\'${filename}"');
  await resp.addStream(f.openRead(start, end + 1));
}

// 判断文件是否是隐藏文件，暂不支持 windows
bool isFileHidden(String path) {
  if (Platform.isWindows) {
    return false;
  }
  return path.startsWith('.');
}

int comparePath(String a, String b) {
  final minLen = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < minLen; i++) {
    var aCode = a.codeUnitAt(i);
    var bCode = b.codeUnitAt(i);
    if (aCode == bCode) {
      continue;
    }
    if (isLetter(aCode) && isLetter(bCode)) {
      // 如果是大写就转为小写
      if (aCode <= 90) {
        aCode += 32;
      }
      // 同上
      if (bCode <= 90) {
        bCode += 32;
      }
      if (aCode == bCode) {
        continue;
      }
      return aCode - bCode;
    }
    if (isNumber(aCode) && isNumber(bCode)) {
      final ii = i + 1;
      final aIndex = checkLastNumber(a, ii);
      final bIndex = checkLastNumber(b, ii);
      final aNumber = parseInt(a, i, aIndex);
      final bNumber = parseInt(b, i, bIndex);
      if (aNumber == bNumber) {
        continue;
      }
      return aNumber - bNumber;
    }
    return aCode - bCode;
  }
  return a.length - b.length;
}

// 左闭右开区间
int parseInt(String s, int startIndex, int endIndex) {
  var result = 0;
  while (startIndex < endIndex) {
    result = result * 10 + s.codeUnitAt(startIndex) - 48;
    startIndex++;
  }
  return result;
}

bool isLetter(int ascii) =>
    ascii >= 65 && ascii <= 90 || ascii >= 97 && ascii <= 122;

bool isNumber(int ascii) => ascii >= 48 && ascii <= 57;

// 返回第一个不是数字的索引
int checkLastNumber(String str, int index) {
  while (index < str.length) {
    if (!isNumber(str.codeUnitAt(index))) {
      break;
    }
    index++;
  }
  return index;
}

void log(String message) {
  stdout.writeln(message);
}
