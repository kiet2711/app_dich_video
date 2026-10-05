import 'dart:io';

import 'package:capsub_flutter/data/model/history_item.dart';
import 'package:capsub_flutter/data/model/subtitle_document.dart';
import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/data/repository/history_repository.dart';
import 'package:capsub_flutter/domain/media/hongguo_prefetch_manager.dart';
import 'package:capsub_flutter/domain/media/hongguo_resolver.dart';
import 'package:capsub_flutter/ui/history/history_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

HistoryItem episode({
  required int index,
  required int timestamp,
  int? lastWatchedAt,
  int positionMs = 0,
  int durationMs = 120000,
}) {
  return HistoryItem(
    id: 'ep-$index',
    title: 'Bộ phim - Tập $index',
    videoPath: '/cache/ep$index.mp4',
    srtPath: '/subs/ep$index.srt',
    timestamp: timestamp,
    durationMs: durationMs,
    lastPositionMs: positionMs,
    lastWatchedAt: lastWatchedAt,
    seriesId: 'series-1',
    episodeIndex: index,
    totalEpisodes: 20,
  );
}

void main() {
  test('prefetched episodes never replace the actual in-progress episode', () {
    final group = DramaHistoryGroup(
      seriesKey: 'series-1',
      seriesId: 'series-1',
      seriesTitle: 'Bộ phim',
      episodes: [
        episode(
            index: 5, timestamp: 5000, lastWatchedAt: 5000, positionMs: 35000),
        episode(index: 6, timestamp: 6000),
        episode(index: 7, timestamp: 7000),
        episode(index: 8, timestamp: 8000),
      ],
    );

    expect(group.latestWatchedEpisode.extractedEpisodeIndex, 5);
    expect(group.lastActivityTimestamp, 5000);
  });

  test('most recently watched episode wins over an older unfinished episode',
      () {
    final group = DramaHistoryGroup(
      seriesKey: 'series-1',
      seriesId: 'series-1',
      seriesTitle: 'Bộ phim',
      episodes: [
        episode(
            index: 4, timestamp: 4000, lastWatchedAt: 4000, positionMs: 20000),
        episode(
            index: 5, timestamp: 9000, lastWatchedAt: 9000, positionMs: 45000),
        episode(index: 6, timestamp: 10000),
      ],
    );

    expect(group.latestWatchedEpisode.extractedEpisodeIndex, 5);
    expect(group.lastActivityTimestamp, 9000);
  });

  test(
      'completed latest episode advances only to its immediate prefetched episode',
      () {
    final group = DramaHistoryGroup(
      seriesKey: 'series-1',
      seriesId: 'series-1',
      seriesTitle: 'Bộ phim',
      episodes: [
        episode(
            index: 5,
            timestamp: 5000,
            lastWatchedAt: 5000,
            positionMs: 96000,
            durationMs: 100000),
        episode(index: 6, timestamp: 6000),
        episode(index: 8, timestamp: 8000),
      ],
    );

    expect(group.latestWatchedEpisode.extractedEpisodeIndex, 6);
    expect(group.lastActivityTimestamp, 5000);
  });

  test('HongguoPrefetchManager preloads existing translated episodes from History', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final tempDir = await Directory.systemTemp.createTemp('prefetch_preload_test_');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall methodCall) async => tempDir.path,
        );

    final detail = const HongguoDramaDetail(
      seriesId: 'series-1',
      title: 'Bộ phim',
      cover: '',
      intro: '',
      totalEpisodes: 20,
    );
    final manager = HongguoPrefetchManager(detail);
    expect(manager.getCachedDocument(6), isNull);

    final ep6Doc = SubtitleDocument([
      SubtitleItem(id: 1, startMs: 0, endMs: 1000, originalText: '你好', translatedText: 'Chào'),
    ]);
    final repo = await HistoryRepository.getInstance();
    final savedEp6 = await repo.saveHistory(
      videoPath: '${tempDir.path}/ep6.mp4',
      title: 'Bộ phim - Tập 6',
      document: ep6Doc,
      durationMs: 80000,
      seriesId: 'series-1',
      episodeIndex: 6,
      isPrefetch: true,
    );

    await manager.preloadFromHistory(seedItems: [savedEp6]);
    expect(manager.getCachedDocument(6), isNotNull);
    expect(manager.getCachedDocument(6)!.items.first.translatedText, 'Chào');

    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });
}
