import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'server.dart';
import 'util.dart';

Future<void> main(List<String> args) async {
  var home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  var port = bool.fromEnvironment('dart.vm.product') ? 80 : 8000;
  var all_files = false;
  {
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
    final p = results['port'];
    if (p != null) {
      port = int.tryParse(p);
    }
    all_files = results['all'];
    if (results['help']) {
      stdout
        ..writeln('用法：${Platform.executable} [-p port] [-a] [home]')
        ..writeln()
        ..writeln('选项：')
        ..writeln(parser.usage);
      return;
    }
    if (results['version']) {
      stdout.writeln('${Platform.executable} 1.0.2');
      return;
    }
    if (results.rest.isNotEmpty) {
      home = results.rest[0];
    }
  }
  if (port == null) {
    logError('端口错误');
    return;
  }
  if (!FileSystemEntity.isDirectorySync(home)) {
    logError('参数错误');
    return;
  }
  await Server(home, port, all_files).startServer();
}
