import 'dart:io';
import 'dart:math';

import 'package:filesize/filesize.dart';
import 'package:http_server/http_server.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'file_item.dart';
import 'util.dart';

class Server {
  static const action_download = 'download';
  static final _date_format = DateFormat('y/MM/dd HH:mm:ss');

  final String _home;
  final int _port;
  final bool _all_files;

  Server(this._home, this._port, this._all_files);

  Future<void> startServer() async {
    final server = await HttpServer.bind('0.0.0.0', _port, backlog: 16);
    await _showTips();
    server.listen(_handleRequest);
  }

  Future<void> _showTips() async {
    log('服务已启动，可使用以下地址访问：');
    _printAddress('127.0.0.1');
    final nis = await NetworkInterface.list(type: InternetAddressType.IPv4);
    nis?.forEach((ni) => _printAddress(ni.addresses[0].address));
  }

  void _printAddress(String address) {
    if (_port != 80) {
      address += ':${_port}';
    }
    stdout.writeln('http://${address}');
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final uriPath = Uri.decodeFull(req.uri.path);
    final resp = req.response;
    try {
      final localPath = p.join(_home, uriPath.startsWith('/') ? uriPath.substring(1) : uriPath);
      if (req.method == 'GET') {
        await _doGet(req, resp, uriPath, localPath);
      } else if (req.method == 'POST') {
        await _doPost(req, resp, localPath);
      } else {
        resp.statusCode = HttpStatus.methodNotAllowed;
      }
      await resp.flush();
      final date = _date_format.format(DateTime.now());
      log('[${date}] ${resp.statusCode} ${uriPath}');
    } catch (e, s) {
      logError(e);
      logError(s);
    } finally {
      await resp.close();
    }
  }

  Future<void> _doGet(HttpRequest req, HttpResponse resp, String uriPath, String localPath) async {
    final stat = await FileStat.stat(localPath);
    switch (stat.type) {
      case FileSystemEntityType.directory:
        // uriPath 必须以 '/' 结尾，否则输出的 html 中的相对路径无法访问
        if (uriPath.endsWith('/')) {
          await _responseDirectory(resp, localPath, uriPath);
        } else {
          await resp.redirect(Uri.parse(uriPath + '/'), status: HttpStatus.movedPermanently);
        }
        break;
      case FileSystemEntityType.file:
        await _responseFile(req, resp, localPath);
        break;
      default:
        resp.statusCode = HttpStatus.notFound;
    }
  }

  Future<void> _doPost(HttpRequest req, HttpResponse resp, String localPath) async {
    var boundary = req.headers.contentType.parameters['boundary'];
    var stream = await MimeMultipartTransformer(boundary).bind(req).map(HttpMultipartFormData.parse);
    await for (var data in stream) {
      final filename = data.contentDisposition.parameters['filename'];
      final ios = File(p.join(localPath, filename)).openWrite();
      try {
        await for (var part in data) {
          ios.add(part);
        }
        await ios.flush();
      } finally {
        await ios.close();
      }
    }
    await resp.redirect(req.uri, status: HttpStatus.movedPermanently);
  }

  Future<void> _responseDirectory(HttpResponse resp, String path, String uriPath) async {
    final dirs = <String>[];
    final files = <FileItem>[];
    // 检查权限
    try {
      await for (var entity in Directory(path).list(followLinks: false)) {
        final stat = await entity.stat();
        var basename = p.basename(entity.path);
        if (_all_files || !isFileHidden(basename)) {
          if (stat.type == FileSystemEntityType.directory) {
            dirs.add(basename + '/');
          } else {
            files.add(FileItem(basename, stat.size));
          }
        }
      }
    } on FileSystemException {
      resp.statusCode = HttpStatus.unauthorized;
      return;
    }
    dirs.sort(comparePath);
    files.sort((a, b) => comparePath(a.name, b.name));
    _writeFileListHtml(resp, uriPath, dirs, files);
  }

  void _writeFileListHtml(HttpResponse resp, String path, List<String> dirs, List<FileItem> files) {
    final title = 'Directory listing for ${path}';
    final dirToHtml = (String dir) => '<li><a href="${dir}">${dir}</a></li>';
    final fileToHtml = (FileItem item) =>
        '<li><a href="${item.name}">${item.name}</a>&nbsp;<span>(${filesize(item.length)})</span>&nbsp;<a href="${item.name}?action=${action_download}">下载</a></li>';
    resp.headers.contentType = ContentType.html;
    resp
      ..write('<head>')
      ..write('<meta name="viewport" content="width=device-width,initial-scale=1.0,minimum-scale=1.0"/>')
      ..write('<title>${title}</title>')
      ..write(
          '<style type="text/css">a{text-decoration:none} a:hover{text-decoration:underline} span{color:#666666}</style>')
      ..write('<script type="text/javascript">')
      ..write('function upload(){var e=document.getElementById(\'fname\');return e.files[0]!=null;}')
      ..write('</script>')
      ..write('</head>')
      ..write('<body>')
      ..write('<h2>${title}</h2>')
      ..write('<hr>')
      ..write('<form method="post" enctype="multipart/form-data" onsubmit="return upload();">')
      ..write('<input id="fname" name="fname" type="file">')
      ..write('<input type="submit" value="上传">')
      ..write('</form>')
      ..write('<ul>')
      ..writeAll(dirs.map<String>(dirToHtml))
      ..writeAll(files.map<String>(fileToHtml))
      ..write('</ul>')
      ..write('</body>');
  }

  Future<void> _responseFile(HttpRequest req, HttpResponse resp, String localPath) async {
    final f = File(localPath);
    // 检查权限
    try {
      final fs = f.openRead(0, 0);
      await fs.forEach((_) {});
    } on FileSystemException {
      resp.statusCode = HttpStatus.unauthorized;
      return;
    }
    final len = await f.length();
    var start = 0;
    var end = len - 1;
    final ranges = req.headers[HttpHeaders.rangeHeader];
    if (ranges != null) {
      if (ranges.length != 1) {
        resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return;
      }
      final range = _Range.parse(ranges[0], len);
      if (range == null) {
        resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return;
      }
      start = range.start;
      end = range.ent;
      resp.statusCode = HttpStatus.partialContent;
    }
    final down = req.uri.queryParameters['action'] == action_download;
    if (len == 0) {
      await _addStream(resp, f, 0, 0, 0, 0, 0, down);
    } else {
      await _addStream(resp, f, start, end, end - start + 1, end + 1, len, down);
    }
  }

  Future<void> _addStream(
      HttpResponse resp, File f, int start, int contentEnd, int contentLen, int fileEnd, int len, bool down) async {
    final type = lookupMimeType(f.path);
    resp.headers
      ..contentType = type != null ? ContentType.parse(type) : ContentType.binary
      ..contentLength = contentLen
      ..add(HttpHeaders.acceptRangesHeader, 'bytes')
      ..add(HttpHeaders.contentRangeHeader, 'bytes ${start}-${contentEnd}/${len}');
    if (down) {
      final filename = Uri.encodeComponent(p.basename(f.path));
      resp.headers.add('Content-Disposition', 'attachment;filename="${filename}";filename*="utf-8\'\'${filename}"');
    }
    await resp.addStream(f.openRead(start, fileEnd));
  }
}

class _Range {
  final int start;
  final int ent;

  _Range(this.start, this.ent);

  static _Range parse(String range, int len) {
    // 这里不用正则表达式了，性能差
    if (!range.startsWith('bytes=')) {
      return null;
    }
    // bytes= 后面
    var index = 6;
    var lastIndex = checkLastNumber(range, index);
    if (lastIndex == index) {
      return null;
    }
    if (lastIndex == range.length || range[lastIndex] != '-') {
      return null;
    }
    final start = parseInt(range, index, lastIndex);
    index = lastIndex + 1;
    lastIndex = checkLastNumber(range, index);
    var end = 0;
    if (lastIndex == index) {
      end = len - 1;
    } else {
      end = min(parseInt(range, index, lastIndex), len - 1);
    }
    if ((len == 0 && start > 0) || (len > 0 && start > end)) {
      return null;
    }
    return _Range(start, end);
  }
}
