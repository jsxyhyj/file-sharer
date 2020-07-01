import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'src/server.dart';
import 'src/server_config.dart';
import 'src/util.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', help: '监听端口，默认为 80')
    ..addFlag('all', abbr: 'a', help: '显示所有文件，默认仅显示非隐藏文件', negatable: false)
    ..addFlag('help', abbr: 'h', help: '显示此帮助信息', negatable: false)
    ..addFlag('version', abbr: 'v', help: '显示版本信息', negatable: false);
  ArgResults results;
  try {
    results = parser.parse(args);
  } on ArgParserException {
    logError('选项或参数错误');
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
  if (results['version']) {
    stdout.writeln('${Platform.executable} 1.0.6');
    return;
  }
  final config = ServerConfig(getUserHomeDirectory(), isDebug ? 80 : 8000, false);
  final p = results['port'];
  if (p != null) {
    try {
      config.port = int.parse(p);
    } catch (e) {
      logError('端口只能为整数');
      return;
    }
  }
  config.all_files = results['all'];
  if (results.rest.isNotEmpty) {
    config.home = results.rest[0];
  }
  if (!FileSystemEntity.isDirectorySync(config.home)) {
    logError('参数错误');
    return;
  }
  await Server(config).startServer();
}
