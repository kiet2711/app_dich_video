import 'dart:io';

import 'package:capsub_flutter/data/model/history_item.dart';
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

  test('self-heals paths when iOS container UUID changes after app update', () async {
    final repo = await HistoryRepository.getInstance();

    // 1. Tạo file SRT và JSON thực sự trong Documents directory hiện tại
    final savedDir = Directory('${tempDir.path}/saved_subtitles');
    await savedDir.create(recursive: true);
    final realSrt = File('${savedDir.path}/sub_uuid_test.srt');
    await realSrt.writeAsString('1\n00:00:00,000 --> 00:00:01,000\nHello\n');

    // 2. Giả lập một HistoryItem được lưu từ bản cài đặt cũ với UUID khác
    const fakeOldUuidPath =
        '/var/mobile/Containers/Data/Application/11111111-2222-3333-4444-555555555555/Documents/saved_subtitles/sub_uuid_test.srt';
    final resolved = await HistoryRepository.resolvePath(fakeOldUuidPath);

    // resolvePath phải tự động tìm thấy file thực tế ở container hiện tại
    expect(resolved, realSrt.path);
    expect(File(resolved).existsSync(), isTrue);

    // 3. Kiểm tra loadSubtitleDocument tự động giải quyết đường dẫn cũ thành công
    final oldItem = HistoryItem(
      id: 'uuid_test',
      title: 'UUID Test',
      videoPath: '/old/video.mp4',
      srtPath: fakeOldUuidPath,
      timestamp: 1000,
      durationMs: 5000,
    );

    final loadedDoc = await repo.loadSubtitleDocument(oldItem);
    expect(loadedDoc, isNotNull);
    expect(loadedDoc!.items.first.originalText, 'Hello');
  });

  test('handles content:// URIs safely in resolvePath and history lifecycle', () async {
    final repo = await HistoryRepository.getInstance();
    const contentUri =
        'content://com.android.providers.media.documents/document/video%3A12345';

    // resolvePath should return the content URI as-is
    final resolved = await HistoryRepository.resolvePath(contentUri);
    expect(resolved, contentUri);

    final doc = SubtitleDocument([
      SubtitleItem(
        id: 1,
        startMs: 0,
        endMs: 2000,
        originalText: 'Content URI video test',
      ),
    ]);

    final item = await repo.saveHistory(
      videoPath: contentUri,
      title: 'Gallery Video',
      document: doc,
      durationMs: 120000,
    );

    expect(item.videoPath, contentUri);

    final list = repo.getHistory();
    expect(list.any((it) => it.videoPath == contentUri), isTrue);

    final loadedDoc = await repo.loadSubtitleDocument(item);
    expect(loadedDoc, isNotNull);
    expect(loadedDoc!.items.first.originalText, 'Content URI video test');

    // Deleting should not throw or attempt to delete content:// URI
    await repo.deleteItem(item.id);
    expect(repo.getHistory().any((it) => it.videoPath == contentUri), isFalse);
  });
}
