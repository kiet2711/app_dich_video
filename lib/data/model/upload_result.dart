class UploadResult {
  final String vid;
  final String md5;
  final int durationMs;
  final int size;
  final String storeUri;

  const UploadResult({
    required this.vid,
    required this.md5,
    required this.durationMs,
    required this.size,
    required this.storeUri,
  });
}
