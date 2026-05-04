import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class MbtilesService {
  static Future<String> copyAssetToFileSystem(
    String assetPath,
    String fileName,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final localPath = '${dir.path}/$fileName';

    debugPrint('Loading asset: $assetPath');

    final data = await rootBundle.load(assetPath);
    debugPrint('Asset bytes: ${data.lengthInBytes}');

    final bytes = data.buffer.asUint8List();
    final file = File(localPath);

    if (await file.exists()) {
      await file.delete();
    }

    await file.writeAsBytes(bytes, flush: true);
    debugPrint('Copied to: $localPath');
    debugPrint('Copied file size: ${await file.length()}');

    return localPath;
  }
}
