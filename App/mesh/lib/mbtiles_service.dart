import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class MbtilesService {
  static Future<String> copyAssetToFileSystem(
    String assetPath,
    String fileName,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final localPath = '${dir.path}/$fileName';

    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List();

    final file = File(localPath);
    await file.writeAsBytes(bytes, flush: true);

    return localPath;
  }
}