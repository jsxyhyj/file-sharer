import 'dart:io';
import 'dart:math';

import 'package:intl/intl.dart';

import 'util.dart';

abstract class BaseRequestHandler {
  static final _date_format = DateFormat('y/MM/dd HH:mm:ss');

  Future<void> handleRequest(HttpRequest req) async {
    final uriPath = Uri.decodeFull(req.uri.path);
    final resp = req.response;
    try {
      if (req.method == 'GET') {
        await doGet(req, resp, uriPath);
      } else if (req.method == 'POST') {
        await doPost(req, resp, uriPath);
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

  Future<void> doGet(HttpRequest req, HttpResponse resp, String uriPath);

  Future<void> doPost(HttpRequest req, HttpResponse resp, String uriPath);
}
