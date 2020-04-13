import 'dart:io';
import 'dart:math';

import 'request_handler.dart';
import 'server_config.dart';
import 'util.dart';

class Server {
  final ServerConfig config;

  Server(this.config);

  Future<void> startServer() async {
    final server = await HttpServer.bind('0.0.0.0', config.port, backlog: 16);
    server.listen(RequestHandler(config).handleRequest);
    await _showTips();
  }

  Future<void> _showTips() async {
    log('服务已启动，可使用以下地址访问：');
    _printAddress('127.0.0.1');
    final nis = await NetworkInterface.list(type: InternetAddressType.IPv4);
    nis?.forEach((ni) => _printAddress(ni.addresses[0].address));
  }

  void _printAddress(String address) {
    if (config.port != 80) {
      address = '${address}:${config.port}';
    }
    stdout.writeln('http://${address}');
  }
}
