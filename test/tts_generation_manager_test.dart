import 'package:capsub_flutter/data/model/subtitle_item.dart';
import 'package:capsub_flutter/domain/tts/tts_generation_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes text that can be synthesized', () {
    expect(TtsGenerationManager.isPronounceable('Xin chào!'), isTrue);
    expect(TtsGenerationManager.isPronounceable('你好'), isTrue);
    expect(TtsGenerationManager.isPronounceable('...?!'), isFalse);
    expect(TtsGenerationManager.isPronounceable('   '), isFalse);
  });

  test('distinguishes a truly blank subtitle from a swallowed translation', () {
    final blank = SubtitleItem(
      id: 1,
      startMs: 0,
      endMs: 1000,
      originalText: '...',
      translatedText: '?',
    );
    final swallowed = SubtitleItem(
      id: 2,
      startMs: 1000,
      endMs: 2000,
      originalText: '你好',
      translatedText: '...',
    );

    expect(TtsGenerationManager.isTrulyBlankSubtitle(blank), isTrue);
    expect(TtsGenerationManager.isTrulyBlankSubtitle(swallowed), isFalse);
  });
}
