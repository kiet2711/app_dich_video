import 'dart:io';

import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/data/repository/history_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('history_test_');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async {
            return tempDir.path;
          },
        );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('saves and loads history item with document', () async {
    final repo = await HistoryRepository.getInstance();
    expect(repo.getHistory(), isEmpty);

    final doc = SubtitleDocument([
      SubtitleItem(
        id: 1,
        startMs: 0,
        endMs: 1500,
        originalText: 'Hello',
        translatedText: 'Xin chào',
      ),
    ]);

    final item = await repo.saveHistory(
      videoPath: '/path/to/video.mp4',
      title: 'video.mp4',
      document: doc,
      durationMs: 5000,
      ttsVoice: 'Thảo Trinh',
    );

    expect(item.videoPath, '/path/to/video.mp4');
    expect(item.sentenceCount, 1);
    expect(item.ttsVoice, 'Thảo Trinh');

    final list = repo.getHistory();
    expect(list.length, 1);
    expect(list.first.title, 'video.mp4');

    // Updating existing video does not lose the item or crash
    final updatedDoc = SubtitleDocument([
      SubtitleItem(
        id: 1,
        startMs: 0,
        endMs: 1500,
        originalText: 'Hello',
        translatedText: 'Xin chào bạn',
      ),
    ]);

    await repo.saveHistory(
      videoPath: '/path/to/video.mp4',
      title: 'video.mp4',
      document: updatedDoc,
      durationMs: 5000,
      ttsVoice: 'Minh Quang',
    );

    final listAfterUpdate = repo.getHistory();
    expect(listAfterUpdate.length, 1);
    expect(listAfterUpdate.first.ttsVoice, 'Minh Quang');

    // Load subtitle document
    final loadedDoc = await repo.loadSubtitleDocument(listAfterUpdate.first);
    expect(loadedDoc, isNotNull);
    expect(loadedDoc!.items.length, 1);
    expect(loadedDoc.items.first.translatedText, 'Xin chào bạn');

    // Delete item
    await repo.deleteItem(item.id);
    expect(repo.getHistory(), isEmpty);
  });
}
