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
    expect(list.first.title, 'video');

    await repo.updatePlaybackPosition(item.id, 3200);
    expect(repo.getHistory().first.lastPositionMs, 3200);

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
    expect(listAfterUpdate.first.lastPositionMs, 3200);

    // Load subtitle document
    final loadedDoc = await repo.loadSubtitleDocument(listAfterUpdate.first);
    expect(loadedDoc, isNotNull);
    expect(loadedDoc!.items.length, 1);
    expect(loadedDoc.items.first.translatedText, 'Xin chào bạn');

    // Delete item
    await repo.deleteItem(item.id);
    expect(repo.getHistory(), isEmpty);
  });

  test('updates shifted SRT and voice document without losing voice metadata', () async {
    final repo = await HistoryRepository.getInstance();
    final original = SubtitleDocument([
      SubtitleItem(
        id: 1,
        startMs: 2000,
        endMs: 4000,
        originalText: 'Original',
        translatedText: 'Bản dịch',
        audioFilePath: '${tempDir.path}/tts/sub_1.mp3',
        audioDurationMs: 1700,
        playbackSpeed: 1.1,
      ),
    ]);
    final saved = await repo.saveHistory(
      videoPath: 'https://www.bilibili.com/video/BV1timing123',
      title: 'Timing test',
      document: original,
      ttsVoice: 'Giọng thử nghiệm',
    );

    final shifted = original.shiftedBy(-1000);
    final updated = await repo.updateSubtitleDocumentForVideo(
      videoPath: 'https://www.bilibili.com/video/BV1timing123?p=1',
      document: shifted,
    );

    expect(updated, isTrue);
    final current = repo.getHistory().single;
    expect(current.ttsVoice, 'Giọng thử nghiệm');
    expect(current.docKey, saved.docKey);
    expect(
      await File(current.srtPath).readAsString(),
      contains('00:00:01,000 --> 00:00:03,000'),
    );

    final reloaded = await repo.loadSubtitleDocument(current);
    expect(reloaded, isNotNull);
    expect(reloaded!.items.single.startMs, 1000);
    expect(reloaded.items.single.endMs, 3000);
    expect(reloaded.items.single.audioFilePath, original.items.single.audioFilePath);
    expect(reloaded.items.single.audioDurationMs, 1700);
    expect(reloaded.items.single.playbackSpeed, 1.1);
  });

  test('updates video title and translated title correctly', () async {
    final repo = await HistoryRepository.getInstance();
    final doc = SubtitleDocument([
      SubtitleItem(
        id: 1,
        startMs: 0,
        endMs: 1000,
        originalText: 'Test',
      ),
    ]);

    final item = await repo.saveHistory(
      videoPath: 'https://www.bilibili.com/video/BV1xx411c7mD',
      title: 'BV1xx411c7mD.mp4',
      document: doc,
    );

    // Initial title has .mp4 stripped
    expect(repo.getHistory().first.title, 'BV1xx411c7mD');
    expect(repo.getHistory().first.displayOriginalTitle, 'BV1xx411c7mD');
    expect(repo.getHistory().first.displayTranslatedTitle, isNull);

    // Update real title
    await repo.updateTitleForVideo('https://www.bilibili.com/video/BV1xx411c7mD', 'Đại Chiến Tam Quốc.mp4');
    expect(repo.getHistory().first.title, 'Đại Chiến Tam Quốc');
    expect(repo.getHistory().first.displayOriginalTitle, 'Đại Chiến Tam Quốc');

    // Update translated title
    await repo.updateTranslatedTitle(item.id, 'Three Kingdoms War.mp4');
    expect(repo.getHistory().first.translatedTitle, 'Three Kingdoms War');
    expect(repo.getHistory().first.displayTranslatedTitle, 'Three Kingdoms War');

    await repo.deleteItem(item.id);
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

  test('uses series and episode as stable identity when Hongguo URL changes', () async {
    final repo = await HistoryRepository.getInstance();
    final doc = SubtitleDocument([
      SubtitleItem(
        id: 1,
        startMs: 0,
        endMs: 1000,
        originalText: '测试',
        translatedText: 'Kiểm tra',
      ),
    ]);

    final first = await repo.saveHistory(
      videoPath: 'https://cdn.example/old-token.mp4',
      title: 'Bộ phim - Tập 5',
      document: doc,
      durationMs: 120000,
      seriesId: 'series-123',
      episodeIndex: 5,
      totalEpisodes: 20,
      isPrefetch: true,
    );
    await repo.updateSeriesPlaybackPosition(
      seriesId: 'series-123',
      episodeIndex: 5,
      positionMs: 42000,
      durationMs: 90000,
    );

    final updated = await repo.saveHistory(
      videoPath: 'https://cdn.example/new-token.mp4',
      title: 'Bộ phim - Tập 5',
      document: doc,
      durationMs: 90000,
      seriesId: 'series-123',
      episodeIndex: 5,
      totalEpisodes: 20,
    );

    final history = repo.getHistory();
    expect(history, hasLength(1));
    expect(updated.id, first.id);
    expect(history.single.videoPath, 'https://cdn.example/new-token.mp4');
    expect(history.single.lastPositionMs, 42000);
    expect(history.single.durationMs, 90000);
  });

  test('updates playback progress only for the currently playing series episode', () async {
    final repo = await HistoryRepository.getInstance();
    final doc = SubtitleDocument([
      SubtitleItem(
        id: 1,
        startMs: 0,
        endMs: 1000,
        originalText: '测试',
      ),
    ]);

    await repo.saveHistory(
      videoPath: '/cache/ep5.mp4',
      title: 'Bộ phim - Tập 5',
      document: doc,
      durationMs: 100000,
      seriesId: 'series-456',
      episodeIndex: 5,
    );
    await repo.saveHistory(
      videoPath: '/cache/ep6.mp4',
      title: 'Bộ phim - Tập 6',
      document: doc,
      durationMs: 80000,
      seriesId: 'series-456',
      episodeIndex: 6,
      isPrefetch: true,
    );

    final didUpdate = await repo.updateSeriesPlaybackPosition(
      seriesId: 'series-456',
      episodeIndex: 6,
      positionMs: 15000,
      durationMs: 80000,
    );
    final history = repo.getHistory();
    final ep5 = history.singleWhere((item) => item.episodeIndex == 5);
    final ep6 = history.singleWhere((item) => item.episodeIndex == 6);

    expect(didUpdate, isTrue);
    expect(ep5.lastPositionMs, 0);
    expect(ep6.lastPositionMs, 15000);
    expect(ep6.lastWatchedAt, isNotNull);
  });

  test('creates backup of original subtitle and restores it correctly', () async {
    final repo = await HistoryRepository.getInstance();
    final originalDoc = SubtitleDocument([
      SubtitleItem(
        id: 1,
        startMs: 1000,
        endMs: 3000,
        originalText: 'Original Audio',
        translatedText: 'Giọng gốc ban đầu',
        audioFilePath: '/audio/1.mp3',
        audioDurationMs: 2000,
      ),
    ]);

    await repo.saveHistory(
      videoPath: 'https://example.com/video.mp4',
      title: 'Video Test',
      document: originalDoc,
      durationMs: 10000,
    );

    // 1. Shift timeline by +1500ms
    final shiftedDoc = originalDoc.shiftedBy(1500);
    final updated = await repo.updateSubtitleDocumentForVideo(
      videoPath: 'https://example.com/video.mp4',
      document: shiftedDoc,
    );
    expect(updated, isTrue);

    // 2. Verify shifted time
    final currentDoc = await repo.loadSubtitleDocument(repo.getHistory().first);
    expect(currentDoc?.items.first.startMs, 2500);
    expect(currentDoc?.items.first.endMs, 4500);

    // 3. Restore to original
    final restoredDoc = await repo.restoreOriginalSubtitleDocumentForVideo(
      videoPath: 'https://example.com/video.mp4',
    );
    expect(restoredDoc, isNotNull);
    expect(restoredDoc?.items.first.startMs, 1000);
    expect(restoredDoc?.items.first.endMs, 3000);
    expect(restoredDoc?.items.first.audioFilePath, '/audio/1.mp3');

    // 4. Verify loaded from disk is back to original
    final reloadedDoc = await repo.loadSubtitleDocument(repo.getHistory().first);
    expect(reloadedDoc?.items.first.startMs, 1000);
    expect(reloadedDoc?.items.first.endMs, 3000);
  });
}
