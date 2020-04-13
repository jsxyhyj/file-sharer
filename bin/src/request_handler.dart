import 'dart:io';

import 'package:filesize/filesize.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'base_request_handler.dart';
import 'file_item.dart';
import 'server_config.dart';
import 'util.dart';

class RequestHandler extends BaseRequestHandler {
  static const _header_content_disposition = 'content-disposition';

  static const _param_action = 'action';
  static const _param_boundary = 'boundary';
  static const _param_filename = 'filename';
  static const _action_download = 'download';

  final ServerConfig config;

  RequestHandler(this.config);

  @override
  Future<void> doGet(HttpRequest req, HttpResponse resp, String uriPath) async {
    final localPath = _getLocalPath(uriPath);
    final stat = await FileStat.stat(localPath);
    switch (stat.type) {
      case FileSystemEntityType.directory:
        // uriPath 必须以 '/' 结尾，否则输出的 html 中的相对路径无法访问
        if (uriPath.endsWith('/')) {
          await _responseDirectory(resp, uriPath, localPath);
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

  @override
  Future<void> doPost(HttpRequest req, HttpResponse resp, String uriPath) async {
    final localPath = _getLocalPath(uriPath);
    var boundary = req.headers.contentType.parameters[_param_boundary];
    var stream = await MimeMultipartTransformer(boundary).bind(req);
    await for (var multipart in stream) {
      if (multipart.headers.containsKey(_header_content_disposition)) {
        final header = HeaderValue.parse(multipart.headers[_header_content_disposition]);
        final filename = header.parameters[_param_filename];
        await _writeMultipartToFile(multipart, p.join(localPath, filename));
      }
    }
    await resp.redirect(req.uri, status: HttpStatus.movedPermanently);
  }

  String _getLocalPath(String uriPath) {
    final localPath = p.join(config.home, uriPath.startsWith('/') ? uriPath.substring(1) : uriPath);
    return localPath;
  }

  Future<void> _writeMultipartToFile(MimeMultipart multipart, String path) async {
    final ios = File(path).openWrite();
    try {
      await ios.addStream(multipart);
      await ios.flush();
    } finally {
      await ios.close();
    }
  }

  Future<void> _responseDirectory(HttpResponse resp, String uriPath, String localPath) async {
    final dirs = <String>[];
    final files = <FileItem>[];
    // 检查权限
    try {
      await _listDir(Directory(localPath), dirs, files);
    } on FileSystemException {
      resp.statusCode = HttpStatus.unauthorized;
      return;
    }
    dirs.sort(comparePath);
    files.sort((a, b) => comparePath(a.name, b.name));
    resp.headers.contentType = ContentType.html;
    resp.write(_generateHtml(uriPath, dirs, files));
  }

  Future<void> _listDir(Directory parent, List<String> dirs, List<FileItem> files) async {
    await for (var entity in parent.list(followLinks: false)) {
      final stat = await entity.stat();
      var basename = p.basename(entity.path);
      if (config.all_files || !isFileHidden(basename)) {
        if (stat.type == FileSystemEntityType.directory) {
          dirs.add(basename + '/');
        } else {
          files.add(FileItem(basename, stat.size));
        }
      }
    }
  }

  String _generateHtml(String uriPath, List<String> dirs, List<FileItem> files) {
    final title = 'Directory listing for ${uriPath}';
    final dirToHtml = (String dir) => '<li><a href="${dir}">${dir}</a></li>';
    final fileToHtml = (FileItem item) =>
        '<li><a href="${item.name}" target="_blank">${item.name}</a>&nbsp;<span>(${filesize(item.length)})</span>&nbsp;<a href="${item.name}?action=${_action_download}" style="font-size:smaller">下载</a></li>';
    final sb = StringBuffer()
      ..write('<head>')
      ..write('<meta name="viewport" content="width=device-width,initial-scale=1.0,minimum-scale=1.0"/>')
      ..write('<title>${title}</title>')
      ..write(
          '<style type="text/css">a{text-decoration:none} a:hover{text-decoration:underline} span{color:#666666;font-size:smaller}</style>')
      ..write('<script type="text/javascript">')
      ..write('function upload(){var e=document.getElementById(\'fname\');return e.files[0]!=null;}')
      ..write('</script>')
      ..write('</head>')
      ..write('<body>')
      ..write('<h2>${title}</h2>')
      ..write('<hr>')
      ..write('<form method="post" enctype="multipart/form-data" onsubmit="return upload();">')
      ..write('<input id="fname" name="fname" type="file" multiple>')
      ..write('<input type="submit" value="上传">')
      ..write('</form>')
      ..write('<ul>')
      ..writeAll(dirs.map<String>(dirToHtml))
      ..writeAll(files.map<String>(fileToHtml))
      ..write('</ul>')
      ..write('</body>');
    return sb.toString();
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
    final down = req.uri.queryParameters[_param_action] == _action_download;
    _addHeadersForFile(resp, f, len, down);
    final ranges = req.headers[HttpHeaders.rangeHeader];
    if (ranges == null) {
      await _addStream(resp, f, 0, len);
      return;
    }
    if (ranges.length != 1) {
      resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    var start = _getRangeStart(ranges[0]);
    if (start == null) {
      resp.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    var end = _getRangeEnd(ranges[0]);
    if (end == null || end >= len) {
      end = len - 1;
    }
    resp.statusCode = HttpStatus.partialContent;
    if (len == 0) {
      _addContentRangeHeader(resp, 0, 0, 0);
      await _addStream(resp, f, 0, 0);
    } else {
      _addContentRangeHeader(resp, start, end, len);
      await _addStream(resp, f, start, end);
    }
  }

  Future<void> _addStream(HttpResponse resp, File f, int start, int end) async {
    await resp.addStream(f.openRead(start, end));
  }

  void _addHeadersForFile(HttpResponse resp, File f, int len, bool down) {
    final type = lookupMimeType(f.path);
    resp.headers
      ..contentType = type != null ? ContentType.parse(type) : ContentType.binary
      ..contentLength = len
      ..add(HttpHeaders.acceptRangesHeader, 'bytes');
    if (down) {
      final filename = Uri.encodeComponent(p.basename(f.path));
      resp.headers
          .add(_header_content_disposition, 'attachment;filename="${filename}";filename*="utf-8\'\'${filename}"');
    }
  }

  void _addContentRangeHeader(HttpResponse resp, int start, int end, int len) {
    resp.headers.add(HttpHeaders.contentRangeHeader, 'bytes ${start}-${end}/${len}');
  }

  int _getRangeStart(String range) {
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
    return parseInt(range, index, lastIndex);
  }

  int _getRangeEnd(String range) {
    var index = range.indexOf('-') + 1;
    var lastIndex = checkLastNumber(range, index);
    if (lastIndex == index) {
      return null;
    }
    return parseInt(range, index, lastIndex);
  }
}
