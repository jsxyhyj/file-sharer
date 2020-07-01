import 'dart:io';

const isDebug = bool.fromEnvironment('dart.vm.product');

String getUserHomeDirectory() => Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];

// 判断文件是否是隐藏文件，暂不支持 windows
bool isFileHidden(String filename) {
  if (Platform.isWindows) {
    return false;
  }
  return filename.startsWith('.');
}

// 判断路径中是否有隐藏路径，暂不支持 Windows
bool isPathHidden(String path) {
  if (Platform.isWindows) {
    return false;
  }
  return path.contains('/.');
}

int comparePath(String a, String b) {
  final minLen = a.length < b.length ? a.length : b.length;
  if (minLen == 0) {
    return a.length - b.length;
  }
  final aCode = a.codeUnitAt(0);
  final bCode = b.codeUnitAt(0);
  var start = 0;
  if (aCode == bCode) {
    start = 1;
  } else {
    if (isDot(aCode)) {
      return -1;
    }
    if (isDot(bCode)) {
      return 1;
    }
  }
  for (var i = start; i < minLen; i++) {
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

bool isLetter(int ascii) => ascii >= 65 && ascii <= 90 || ascii >= 97 && ascii <= 122;

bool isNumber(int ascii) => ascii >= 48 && ascii <= 57;

bool isDot(int ascii) => ascii == 46;

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

void logError(dynamic e) {
  stderr.writeln(e.toString());
}
