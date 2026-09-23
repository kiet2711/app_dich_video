import 'package:capsub_flutter/domain/tts/tts_generation_manager.dart';
import 'package:capsub_flutter/ui/tts/tts_error_review_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the original error recovery actions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TtsErrorReviewDialog(
            failedItems: const [
              TtsFailedItem(
                itemId: 9,
                text: '你好',
                reason: 'Bản dịch bị nuốt/chỉ chứa dấu câu',
              ),
            ],
            threadCount: 50,
            geminiThreadCount: 2,
            geminiApiKeysAvailable: true,
            onRetryOne: (_, _) async {},
            onRetryAll: (_) async {},
            onTranslateWithGemini: (_, _) async => const {},
            onTranslateSingleWithGemini: (_, text) async => text,
            onSkipErrors: () async {},
          ),
        ),
      ),
    );

    expect(find.textContaining('Xử lý 1 câu'), findsOneWidget);
    expect(find.text('Dịch AI'), findsOneWidget);
    expect(find.text('Thử lại câu này'), findsOneWidget);
    expect(find.textContaining('Thử tạo lại tất cả'), findsOneWidget);
    expect(find.text('Bỏ qua các câu lỗi và tiếp tục'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
