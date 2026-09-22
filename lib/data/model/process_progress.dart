import 'subtitle_document.dart';

enum ProcessStage {
  idle,
  extractingAudio, // Giai đoạn 1: Tách âm thanh M4A từ video
  uploadingVod, // Giai đoạn 2: Tải âm thanh lên CapCut Cloud
  sttTranscribing, // Giai đoạn 3: AI CapCut nhận diện giọng nói
  aiTranslating, // Giai đoạn 4: Gemini dịch phụ đề sang tiếng Việt
  completed, // Hoàn tất
  error, // Lỗi
  cancelled, // Huỷ bởi người dùng
}

class ProcessProgress {
  final ProcessStage stage;
  final double progress; // Từ 0.0 đến 1.0
  final String message;
  final Object? error;
  final SubtitleDocument? resultDocument;

  const ProcessProgress({
    this.stage = ProcessStage.idle,
    this.progress = 0.0,
    this.message = '',
    this.error,
    this.resultDocument,
  });

  bool get isRunning =>
      stage == ProcessStage.extractingAudio ||
      stage == ProcessStage.uploadingVod ||
      stage == ProcessStage.sttTranscribing ||
      stage == ProcessStage.aiTranslating;
}
