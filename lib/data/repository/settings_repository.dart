import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/ai/ai_model_registry.dart';

class SettingsRepository {
  static SettingsRepository? _instance;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  final SharedPreferences prefs;
  String _geminiApiKeysRaw;
  String _groqApiKeysRaw;
  String _bilibiliSessData;

  SettingsRepository._(
    this.prefs,
    this._geminiApiKeysRaw,
    this._groqApiKeysRaw,
    this._bilibiliSessData,
  );

  static Future<SettingsRepository> getInstance() async {
    if (_instance == null) {
      final sp = await SharedPreferences.getInstance();
      var apiKeys = await _secureStorage.read(key: 'gemini_api_keys') ?? '';
      var groqKeys = await _secureStorage.read(key: 'groq_api_keys') ?? '';
      var sessData = await _secureStorage.read(key: 'bilibili_sessdata') ?? '';

      final legacyApiKeys = sp.getString('gemini_api_keys') ?? '';
      final legacySessData = sp.getString('bilibili_sessdata') ?? '';
      if (apiKeys.isEmpty && legacyApiKeys.isNotEmpty) {
        apiKeys = legacyApiKeys;
        await _secureStorage.write(key: 'gemini_api_keys', value: apiKeys);
        await sp.remove('gemini_api_keys');
      }
      if (sessData.isEmpty && legacySessData.isNotEmpty) {
        sessData = legacySessData;
        await _secureStorage.write(key: 'bilibili_sessdata', value: sessData);
        await sp.remove('bilibili_sessdata');
      }
      _instance = SettingsRepository._(sp, apiKeys, groqKeys, sessData);
      _instance!._syncCustomModelsToRegistry();
    }
    return _instance!;
  }

  void _syncCustomModelsToRegistry() {
    AiModelRegistry.updateCustomModels(
      geminiModels: customGeminiModels,
      groqModels: customGroqModels,
    );
  }

  /// Đọc lại API key mới nhất từ Secure Storage (tránh cache cũ nếu màn khác vừa lưu).
  Future<void> reloadSecureKeys() async {
    try {
      final freshGemini = await _secureStorage.read(key: 'gemini_api_keys');
      if (freshGemini != null && freshGemini.trim().isNotEmpty) {
        _geminiApiKeysRaw = freshGemini;
      } else {
        final legacy = prefs.getString('gemini_api_keys');
        if (legacy != null && legacy.trim().isNotEmpty) {
          _geminiApiKeysRaw = legacy;
        }
      }
      final freshGroq = await _secureStorage.read(key: 'groq_api_keys');
      if (freshGroq != null && freshGroq.trim().isNotEmpty) {
        _groqApiKeysRaw = freshGroq;
      }
    } catch (_) {}
  }

  List<String> get geminiApiKeys {
    return _geminiApiKeysRaw
        .split(RegExp(r'[,;\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  set geminiApiKeys(List<String> value) {
    _geminiApiKeysRaw = value.join('\n');
    unawaited(
      _secureStorage.write(key: 'gemini_api_keys', value: _geminiApiKeysRaw),
    );
  }

  List<String> get groqApiKeys {
    return _groqApiKeysRaw
        .split(RegExp(r'[,;\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  set groqApiKeys(List<String> value) {
    _groqApiKeysRaw = value.join('\n');
    unawaited(
      _secureStorage.write(key: 'groq_api_keys', value: _groqApiKeysRaw),
    );
  }

  String get selectedModel =>
      prefs.getString('selected_model') ?? 'gemini-3.1-flash-lite';
  set selectedModel(String v) => prefs.setString('selected_model', v);

  String get selectedGroqModel =>
      prefs.getString('selected_groq_model') ?? 'openai/gpt-oss-120b';
  set selectedGroqModel(String v) =>
      prefs.setString('selected_groq_model', v.trim());

  String get selectedGeminiModel =>
      prefs.getString('selected_gemini_model') ?? 'gemini-3.1-flash-lite';
  set selectedGeminiModel(String v) => prefs.setString(
    'selected_gemini_model',
    AiModelRegistry.normalizeModelId(v),
  );

  List<String> get customGeminiModels =>
      (prefs.getStringList('custom_gemini_models') ?? const <String>[])
          .map(AiModelRegistry.normalizeModelId)
          .where((id) => id.isNotEmpty)
          .toList();

  set customGeminiModels(List<String> value) {
    final cleaned = value
        .map(AiModelRegistry.normalizeModelId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    prefs.setStringList('custom_gemini_models', cleaned);
    _syncCustomModelsToRegistry();
  }

  List<String> get customGroqModels =>
      (prefs.getStringList('custom_groq_models') ?? const <String>[])
          .map(AiModelRegistry.normalizeModelId)
          .where((id) => id.isNotEmpty)
          .toList();

  set customGroqModels(List<String> value) {
    final cleaned = value
        .map(AiModelRegistry.normalizeModelId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    prefs.setStringList('custom_groq_models', cleaned);
    _syncCustomModelsToRegistry();
  }

  void addCustomGeminiModel(String modelId) {
    final clean = AiModelRegistry.normalizeModelId(modelId);
    if (clean.isEmpty) return;
    final list = List<String>.from(customGeminiModels);
    if (!list.contains(clean)) {
      list.add(clean);
      customGeminiModels = list;
    }
  }

  void removeCustomGeminiModel(String modelId) {
    final clean = AiModelRegistry.normalizeModelId(modelId);
    final list = customGeminiModels.where((id) => id != clean).toList();
    customGeminiModels = list;
    if (selectedGeminiModel == clean) {
      selectedGeminiModel = 'gemini-3.1-flash-lite';
    }
    if (selectedModel == clean) {
      selectedModel = 'gemini-3.1-flash-lite';
    }
  }

  void addCustomGroqModel(String modelId) {
    final clean = AiModelRegistry.normalizeModelId(modelId);
    if (clean.isEmpty) return;
    final list = List<String>.from(customGroqModels);
    if (!list.contains(clean)) {
      list.add(clean);
      customGroqModels = list;
    }
  }

  void removeCustomGroqModel(String modelId) {
    final clean = AiModelRegistry.normalizeModelId(modelId);
    final list = customGroqModels.where((id) => id != clean).toList();
    customGroqModels = list;
    if (selectedGroqModel == clean) {
      selectedGroqModel = 'openai/gpt-oss-120b';
    }
    if (selectedModel == clean) {
      selectedModel = 'openai/gpt-oss-120b';
    }
  }

  String get selectedStyle => prefs.getString('selected_style') ?? 'Zhihu';
  set selectedStyle(String v) => prefs.setString('selected_style', v);

  String get defaultSourceLanguage => prefs.getString('source_lang') ?? 'zh-CN';
  set defaultSourceLanguage(String v) => prefs.setString('source_lang', v);

  double get subtitleFontSize =>
      (prefs.getDouble('sub_font_size') ?? 14.0).clamp(5.0, 30.0);
  set subtitleFontSize(double v) =>
      prefs.setDouble('sub_font_size', v.clamp(5.0, 30.0));

  String get selectedFontFamily =>
      prefs.getString('selected_font_family') ?? '';
  set selectedFontFamily(String v) =>
      prefs.setString('selected_font_family', v.trim());

  List<String> get customFonts =>
      prefs.getStringList('custom_fonts') ?? <String>[];
  set customFonts(List<String> v) => prefs.setStringList('custom_fonts', v);

  bool get isBlackBoxEnabled => prefs.getBool('blackbox_enabled') ?? false;
  set isBlackBoxEnabled(bool v) => prefs.setBool('blackbox_enabled', v);

  double get blackBoxHeight => prefs.getDouble('blackbox_height') ?? 64.0;
  set blackBoxHeight(double v) => prefs.setDouble('blackbox_height', v);

  double get blackBoxOpacity => prefs.getDouble('blackbox_opacity') ?? 0.92;
  set blackBoxOpacity(double v) => prefs.setDouble('blackbox_opacity', v);

  static const double defaultPortraitSubtitlePosition = 0.24;
  static const double defaultLandscapeSubtitlePosition = 0.06;

  static double defaultSubtitlePosition({required bool isLandscape}) =>
      isLandscape
      ? defaultLandscapeSubtitlePosition
      : defaultPortraitSubtitlePosition;

  double get subtitlePosPortrait =>
      (prefs.getDouble('sub_pos_portrait') ?? defaultPortraitSubtitlePosition)
          .clamp(0.0, 1.0);
  set subtitlePosPortrait(double v) =>
      prefs.setDouble('sub_pos_portrait', v.clamp(0.0, 1.0));

  double get subtitlePosLandscape =>
      (prefs.getDouble('sub_pos_landscape') ?? defaultLandscapeSubtitlePosition)
          .clamp(0.0, 1.0);
  set subtitlePosLandscape(double v) =>
      prefs.setDouble('sub_pos_landscape', v.clamp(0.0, 1.0));

  double getSubtitlePosition({required bool isLandscape}) =>
      isLandscape ? subtitlePosLandscape : subtitlePosPortrait;

  void setSubtitlePosition(double value, {required bool isLandscape}) {
    if (isLandscape) {
      subtitlePosLandscape = value;
    } else {
      subtitlePosPortrait = value;
    }
  }

  double get subtitleOffsetY => prefs.getDouble('sub_offset_y') ?? 90.0;
  set subtitleOffsetY(double v) => prefs.setDouble('sub_offset_y', v);

  String get subtitleColorHex => prefs.getString('sub_color_hex') ?? '#FFFFFF';
  set subtitleColorHex(String v) => prefs.setString('sub_color_hex', v);

  String get subtitleMode => prefs.getString('sub_mode') ?? 'translated';
  set subtitleMode(String v) => prefs.setString('sub_mode', v);

  bool get isTtsPlaybackEnabled =>
      prefs.getBool('tts_playback_enabled') ?? true;
  set isTtsPlaybackEnabled(bool v) => prefs.setBool('tts_playback_enabled', v);

  double get originalVideoVolume =>
      prefs.getDouble('original_video_volume') ?? 0.57;
  set originalVideoVolume(double v) =>
      prefs.setDouble('original_video_volume', v.clamp(0.0, 1.0));

  double get ttsVolume => prefs.getDouble('tts_volume') ?? 0.72;
  set ttsVolume(double v) => prefs.setDouble('tts_volume', v.clamp(0.0, 1.0));

  double get ttsVoicePitch =>
      (prefs.getDouble('tts_voice_pitch') ?? 1.0).clamp(0.75, 1.25);
  set ttsVoicePitch(double v) =>
      prefs.setDouble('tts_voice_pitch', v.clamp(0.75, 1.25));

  double get ttsVoiceWarmth =>
      (prefs.getDouble('tts_voice_warmth') ?? 0.0).clamp(-1.0, 1.0);
  set ttsVoiceWarmth(double v) =>
      prefs.setDouble('tts_voice_warmth', v.clamp(-1.0, 1.0));

  double get ttsVoiceBrightness =>
      (prefs.getDouble('tts_voice_brightness') ?? 0.0).clamp(-1.0, 1.0);
  set ttsVoiceBrightness(double v) =>
      prefs.setDouble('tts_voice_brightness', v.clamp(-1.0, 1.0));

  String get geminiCustomPrompt =>
      prefs.getString('gemini_custom_prompt') ?? '';
  set geminiCustomPrompt(String v) =>
      prefs.setString('gemini_custom_prompt', v);

  String get targetLanguage => prefs.getString('target_lang') ?? 'vi-VN';
  set targetLanguage(String v) => prefs.setString('target_lang', v);

  String get targetLanguageLabel =>
      prefs.getString('target_lang_label') ?? '🇻🇳 Tiếng Việt (Mặc định)';
  set targetLanguageLabel(String v) => prefs.setString('target_lang_label', v);

  int get geminiThreadCount =>
      (prefs.getInt('gemini_thread_count') ?? 7).clamp(1, 20);
  set geminiThreadCount(int v) =>
      prefs.setInt('gemini_thread_count', v.clamp(1, 20));

  int get geminiBatchSize =>
      (prefs.getInt('gemini_batch_size') ?? 100).clamp(10, 200);
  set geminiBatchSize(int v) =>
      prefs.setInt('gemini_batch_size', v.clamp(10, 200));

  int get groqThreadCount =>
      (prefs.getInt('groq_thread_count') ?? 3).clamp(1, 20);
  set groqThreadCount(int v) =>
      prefs.setInt('groq_thread_count', v.clamp(1, 20));

  int get groqBatchSize =>
      (prefs.getInt('groq_batch_size') ?? 45).clamp(10, 200);
  set groqBatchSize(int v) => prefs.setInt('groq_batch_size', v.clamp(10, 200));

  bool get enableSmartModelFallback =>
      prefs.getBool('enable_smart_model_fallback') ?? true;
  set enableSmartModelFallback(bool v) =>
      prefs.setBool('enable_smart_model_fallback', v);

  bool get enableCrossProviderFallback =>
      prefs.getBool('enable_cross_provider_fallback') ?? true;
  set enableCrossProviderFallback(bool v) =>
      prefs.setBool('enable_cross_provider_fallback', v);

  bool get enableDualModelBalancing =>
      prefs.getBool('enable_dual_model_balancing') ?? true;
  set enableDualModelBalancing(bool v) =>
      prefs.setBool('enable_dual_model_balancing', v);

  int get downloadThreadCount =>
      (prefs.getInt('download_thread_count') ?? 16).clamp(8, 32);
  set downloadThreadCount(int v) =>
      prefs.setInt('download_thread_count', v.clamp(8, 32));

  int get capcutSttConcurrency =>
      (prefs.getInt('capcut_stt_concurrency') ?? 10).clamp(1, 20);
  set capcutSttConcurrency(int v) =>
      prefs.setInt('capcut_stt_concurrency', v.clamp(1, 20));

  int get audioSliceConcurrency =>
      (prefs.getInt('audio_slice_concurrency') ?? 10).clamp(1, 20);
  set audioSliceConcurrency(int v) =>
      prefs.setInt('audio_slice_concurrency', v.clamp(1, 20));

  int get audioChunkDurationMin =>
      (prefs.getInt('audio_chunk_duration_min') ?? 10).clamp(1, 15);
  set audioChunkDurationMin(int v) =>
      prefs.setInt('audio_chunk_duration_min', v.clamp(1, 15));

  int get audioChunkDurationSec => audioChunkDurationMin * 60;

  int get ttsThreadCount =>
      (prefs.getInt('tts_thread_count') ?? 50).clamp(1, 100);
  set ttsThreadCount(int v) =>
      prefs.setInt('tts_thread_count', v.clamp(1, 100));

  String get selectedTtsVoice =>
      prefs.getString('selected_tts_voice') ?? 'BV074_streaming_dsp';
  set selectedTtsVoice(String v) => prefs.setString('selected_tts_voice', v);

  String get bilibiliSessData => _bilibiliSessData;
  set bilibiliSessData(String v) {
    _bilibiliSessData = v.trim();
    unawaited(
      _secureStorage.write(key: 'bilibili_sessdata', value: _bilibiliSessData),
    );
  }

  String get bilibiliBiliJct => prefs.getString('bilibili_bili_jct') ?? '';
  set bilibiliBiliJct(String v) =>
      prefs.setString('bilibili_bili_jct', v.trim());

  Set<int> get bilibiliFollowedMids {
    final list = prefs.getStringList('bilibili_followed_mids') ?? const [];
    return list.map((e) => int.tryParse(e) ?? 0).where((m) => m > 0).toSet();
  }

  void addBilibiliFollowedMid(int mid) {
    if (mid <= 0) return;
    final set = bilibiliFollowedMids;
    set.add(mid);
    prefs.setStringList(
      'bilibili_followed_mids',
      set.map((e) => e.toString()).toList(),
    );
  }

  void removeBilibiliFollowedMid(int mid) {
    if (mid <= 0) return;
    final set = bilibiliFollowedMids;
    set.remove(mid);
    prefs.setStringList(
      'bilibili_followed_mids',
      set.map((e) => e.toString()).toList(),
    );
  }

  bool isBilibiliMidFollowed(int mid) {
    if (mid <= 0) return false;
    return bilibiliFollowedMids.contains(mid);
  }

  String get bilibiliPreferredQuality =>
      prefs.getString('bilibili_preferred_quality') ?? '80';
  set bilibiliPreferredQuality(String v) =>
      prefs.setString('bilibili_preferred_quality', v);

  int get prefetchEpisodeCount =>
      (prefs.getInt('prefetch_episode_count') ?? 2).clamp(1, 5);
  set prefetchEpisodeCount(int v) =>
      prefs.setInt('prefetch_episode_count', v.clamp(1, 5));

  bool get autoPlayNextEpisode =>
      prefs.getBool('auto_play_next_episode') ?? true;
  set autoPlayNextEpisode(bool v) => prefs.setBool('auto_play_next_episode', v);

  // ===== CẤU HÌNH DỊCH ĐỘC LẬP CHO PHIM NGẮN HỒNG QUẢ (ZH -> VI) =====
  static const String defaultHongguoPrompt =
      'Bạn là chuyên gia biên kịch và dịch thuật phụ đề phim ngắn Trung Quốc (vi đoản kịch, tổng tài, ngôn tình, đô thị, trọng sinh, chiến thần, cung đấu).\n'
      'Nhiệm vụ: Dịch phụ đề từ tiếng Trung (zh-CN) sang tiếng Việt (vi-VN) chuẩn văn phong phim ảnh, mượt mà, cảm xúc và tự nhiên.\n'
      'Yêu cầu:\n'
      '- Xưng hô nhân vật đúng ngữ cảnh, thân phận, vai vế (tổng tài, phu nhân, thiếu gia, thuộc hạ, bạn bè, đối thủ...).\n'
      '- Giữ nguyên tên riêng Hán-Việt phổ biến, chuyển ngữ các câu thoại thành ngữ/tiếng lóng tự nhiên, bắt tai.\n'
      '- Câu từ ngắn gọn, súc tích, khớp nhịp thoại nhanh của phim ngắn.\n'
      '- Giữ nguyên số dòng và định dạng, chỉ trả về nội dung bản dịch tiếng Việt.';

  /// Bật/tắt tự động dịch tiêu đề & mô tả Hồng Quả bằng ML Kit
  bool get hongguoTranslateEnabled =>
      prefs.getBool('hongguo_translate_enabled') ?? true;
  set hongguoTranslateEnabled(bool v) =>
      prefs.setBool('hongguo_translate_enabled', v);

  /// Tùy chọn hiện 4 nút phụ ra ngoài cột phải màn hình lướt Hồng Quả
  bool get hongguoFeedShowLiveButton =>
      prefs.getBool('hongguo_feed_show_live_btn') ?? false;
  set hongguoFeedShowLiveButton(bool v) =>
      prefs.setBool('hongguo_feed_show_live_btn', v);

  bool get hongguoFeedShowSaveButton =>
      prefs.getBool('hongguo_feed_show_save_btn') ?? false;
  set hongguoFeedShowSaveButton(bool v) =>
      prefs.setBool('hongguo_feed_show_save_btn', v);

  bool get hongguoFeedShowSimilarButton =>
      prefs.getBool('hongguo_feed_show_similar_btn') ?? false;
  set hongguoFeedShowSimilarButton(bool v) =>
      prefs.setBool('hongguo_feed_show_similar_btn', v);

  bool get hongguoFeedShowHideButton =>
      prefs.getBool('hongguo_feed_show_hide_btn') ?? false;
  set hongguoFeedShowHideButton(bool v) =>
      prefs.setBool('hongguo_feed_show_hide_btn', v);

  /// Chế độ dịch riêng của Hồng Quả: 'capcut' (CapCut Free) hoặc 'api_online' (API Online tự động xoay model & key)
  String get hongguoTranslationMode =>
      prefs.getString('hongguo_translation_mode') ?? 'api_online';
  set hongguoTranslationMode(String v) =>
      prefs.setString('hongguo_translation_mode', v);

  /// Engine lấy và giải mã video Hồng Quả: 'local' hoặc 'hf'.
  /// Hệ thống ưu tiên engine được chọn và tự động fallback sang engine còn lại nếu gặp lỗi.
  String get hongguoVideoResolverEngine =>
      prefs.getString('hongguo_video_resolver_engine') ?? 'local';
  set hongguoVideoResolverEngine(String v) => prefs.setString(
    'hongguo_video_resolver_engine',
    v == 'hf' ? 'hf' : 'local',
  );

  /// Chất lượng ưu tiên cho video Hongguo: '1080', '720', '480', '360', 'auto'.
  static const List<String> validHongguoQualities = <String>[
    '1080',
    '720',
    '480',
    '360',
    'auto',
  ];

  String get hongguoPreferredQuality =>
      prefs.getString('hongguo_preferred_quality') ?? '1080';
  set hongguoPreferredQuality(String v) {
    final clean = validHongguoQualities.contains(v) ? v : '1080';
    prefs.setString('hongguo_preferred_quality', clean);
  }

  /// Giọng đọc lồng tiếng AI riêng cho phim ngắn Hồng Quả
  String get hongguoSelectedTtsVoice =>
      prefs.getString('hongguo_selected_tts_voice') ?? selectedTtsVoice;
  set hongguoSelectedTtsVoice(String v) =>
      prefs.setString('hongguo_selected_tts_voice', v);

  /// Tự động xóa các tập đã xem trước (giữ lại 3 tập gần nhất) của phim Hồng Quả
  bool get hongguoAutoDeleteWatched =>
      prefs.getBool('hongguo_auto_delete_watched') ?? true;
  set hongguoAutoDeleteWatched(bool v) =>
      prefs.setBool('hongguo_auto_delete_watched', v);

  /// Tốc độ phát video mặc định / ghi nhớ cho phim ngắn Hồng Quả (0.5x -> 2.0x)
  double get hongguoPlaybackSpeed =>
      (prefs.getDouble('hongguo_playback_speed') ?? 1.0).clamp(0.5, 2.0);
  set hongguoPlaybackSpeed(double v) =>
      prefs.setDouble('hongguo_playback_speed', v.clamp(0.5, 2.0));

  /// Tự động chuyển tập cho phim Hồng Quả khi xem hết video
  bool get hongguoAutoNextEpisode =>
      prefs.getBool('hongguo_auto_next_ep') ?? false;
  set hongguoAutoNextEpisode(bool v) =>
      prefs.setBool('hongguo_auto_next_ep', v);

  /// Số tập dịch trước trong nền khi bật tự chuyển tập (1, 2, 3, 5)
  int get hongguoPreTranslateCount =>
      prefs.getInt('hongguo_pre_translate_count') ?? 2;
  set hongguoPreTranslateCount(int v) =>
      prefs.setInt('hongguo_pre_translate_count', v);

  /// Chế độ xử lý trước: 'sub_and_tts' (Cả Vietsub & Lồng tiếng) hoặc 'sub_only' (Chỉ Vietsub)
  String get hongguoPreTranslateMode =>
      prefs.getString('hongguo_pre_translate_mode') ?? 'sub_and_tts';
  set hongguoPreTranslateMode(String v) =>
      prefs.setString('hongguo_pre_translate_mode', v);

  /// Lưu Tab hiện tại của màn hình Lướt Hồng Quả: 'follow', 'comic', 'real', 'discover'
  String get hongguoFeedTab {
    final stored = prefs.getString('hongguo_feed_tab') ?? 'comic';
    if (stored == 'follow' ||
        stored == 'comic' ||
        stored == 'real' ||
        stored == 'discover') {
      return stored;
    }
    return 'comic';
  }

  set hongguoFeedTab(String v) => prefs.setString('hongguo_feed_tab', v);

  /// Lưu Dạng phim / Danh mục đã chọn trong tab Lướt: 'category/real-drama', 'category/comic-drama', 'category/ai-drama'
  String get hongguoFeedCategory =>
      prefs.getString('hongguo_feed_category') ?? 'category/real-drama';
  set hongguoFeedCategory(String v) =>
      prefs.setString('hongguo_feed_category', v);

  /// Lưu slug thể loại (rỗng nghĩa là Tất cả của dạng phim đó)
  String get hongguoFeedGenreSlug =>
      prefs.getString('hongguo_feed_genre_slug') ?? '';
  set hongguoFeedGenreSlug(String v) =>
      prefs.setString('hongguo_feed_genre_slug', v);

  /// Lưu nhãn tiếng Việt của thể loại / dạng phim
  String get hongguoFeedGenreLabel =>
      prefs.getString('hongguo_feed_genre_label') ?? 'Người thật';
  set hongguoFeedGenreLabel(String v) =>
      prefs.setString('hongguo_feed_genre_label', v);

  /// Lưu tag tiếng Trung tương ứng
  String get hongguoFeedZhTag => prefs.getString('hongguo_feed_zh_tag') ?? '全部';
  set hongguoFeedZhTag(String v) => prefs.setString('hongguo_feed_zh_tag', v);

  /// Danh sách các phim Hồng Quả người dùng đã xem gần đây (để ưu tiên hiển thị phim mới)
  List<String> get hongguoSeenSeriesIds =>
      prefs.getStringList('hongguo_seen_series_ids') ?? [];

  void addHongguoSeenSeriesId(String id) {
    if (id.isEmpty) return;
    final list = List<String>.from(
      prefs.getStringList('hongguo_seen_series_ids') ?? [],
    );
    list.remove(id);
    list.insert(0, id);
    if (list.length > 200) {
      list.removeRange(200, list.length);
    }
    prefs.setStringList('hongguo_seen_series_ids', list);
  }

  /// Trang thể loại đã duyệt gần nhất
  int get hongguoFeedGenrePage => prefs.getInt('hongguo_feed_genre_page') ?? 1;
  set hongguoFeedGenrePage(int v) => prefs.setInt('hongguo_feed_genre_page', v);

  /// Trang thịnh hành đã duyệt gần nhất
  int get hongguoFeedTrendingPage =>
      prefs.getInt('hongguo_feed_trending_page') ?? 1;
  set hongguoFeedTrendingPage(int v) =>
      prefs.setInt('hongguo_feed_trending_page', v);

  /// Trạng thái bộ lọc đa chiều (JSON) cho màn hình Lướt Shorts Hồng Quả
  String get hongguoFeedDiscoveryJson =>
      prefs.getString('hongguo_feed_discovery_json') ?? '';
  set hongguoFeedDiscoveryJson(String v) =>
      prefs.setString('hongguo_feed_discovery_json', v);

  /// Trạng thái bộ lọc đa chiều (JSON) cho Kho Phim Hồng Quả
  String get hongguoCatalogDiscoveryJson =>
      prefs.getString('hongguo_catalog_discovery_json') ?? '';
  set hongguoCatalogDiscoveryJson(String v) =>
      prefs.setString('hongguo_catalog_discovery_json', v);

  /// Chế độ dịch riêng của Bilibili: 'capcut' (CapCut Free) hoặc 'api_online' (AI Online)
  String get bilibiliTranslationMode =>
      prefs.getString('bilibili_translation_mode') ?? 'api_online';
  set bilibiliTranslationMode(String v) =>
      prefs.setString('bilibili_translation_mode', v);

  /// Dung lượng bộ nhớ đệm RAM cho trình phát MediaKit (MB): 32, 64, 128 (mặc định), 256
  int get playerBufferSizeMb =>
      (prefs.getInt('player_buffer_size_mb') ?? 128).clamp(32, 256);
  set playerBufferSizeMb(int v) =>
      prefs.setInt('player_buffer_size_mb', v.clamp(32, 256));

  /// Nguồn lấy phụ đề gốc cho video Bilibili:
  /// 'bilibili_first': Ưu tiên phụ đề gốc Bilibili (nếu có, nếu không mới qua CapCut) - mặc định
  /// 'capcut_always': Bỏ qua phụ đề Bilibili, luôn nhận diện âm thanh trực tiếp qua CapCut STT
  String get bilibiliSubtitleSource =>
      prefs.getString('bilibili_subtitle_source') ?? 'bilibili_first';
  set bilibiliSubtitleSource(String v) =>
      prefs.setString('bilibili_subtitle_source', v);

  /// Định dạng luồng phát video Bilibili khi xem trực tuyến:
  /// 'dash': Luồng DASH tách rời video & audio gốc của Bilibili (mặc định hiện tại)
  /// 'muxed': Luồng MP4 gộp sẵn video + audio (tua mượt mà, không bị ngắt hoặc mất tiếng khi tua)
  String get bilibiliStreamMode =>
      prefs.getString('bilibili_stream_mode') ?? 'dash';
  set bilibiliStreamMode(String v) =>
      prefs.setString('bilibili_stream_mode', v);

  /// Máy chủ CDN ưu tiên cho Bilibili: 'auto' (né MCDN), 'akamai', 'ali', 'cos', 'hw', 'origin'
  String get bilibiliCdnService =>
      prefs.getString('bilibili_cdn_service') ?? 'auto';
  set bilibiliCdnService(String v) =>
      prefs.setString('bilibili_cdn_service', v);

  /// Bật giải mã phần cứng GPU cho trình phát video (giảm nóng/giật khi xem Bilibili)
  bool get bilibiliHardwareDecode =>
      prefs.getBool('bilibili_hw_decode') ?? true;
  set bilibiliHardwareDecode(bool v) => prefs.setBool('bilibili_hw_decode', v);

  /// Giọng đọc lồng tiếng AI riêng cho Bilibili
  String get bilibiliSelectedTtsVoice =>
      prefs.getString('bilibili_selected_tts_voice') ?? selectedTtsVoice;
  set bilibiliSelectedTtsVoice(String v) =>
      prefs.setString('bilibili_selected_tts_voice', v);

  /// Tùy chọn tải video Bilibili về máy để phát offline (chống giật lag)
  bool get downloadBilibiliVideo =>
      prefs.getBool('download_bilibili_video') ?? false;
  set downloadBilibiliVideo(bool v) =>
      prefs.setBool('download_bilibili_video', v);

  /// Prompt ngữ cảnh dịch riêng dành riêng cho phim ngắn Hồng Quả
  String get hongguoCustomPrompt =>
      prefs.getString('hongguo_custom_prompt') ?? defaultHongguoPrompt;
  set hongguoCustomPrompt(String v) =>
      prefs.setString('hongguo_custom_prompt', v);

  /// Chất lượng video ưu tiên khi phát online hoặc tải về: '80' (1080p - mặc định), '64' (720p), '32' (480p), '16' (360p)
  String get preferredVideoQuality =>
      prefs.getString('preferred_video_quality') ?? '80';
  set preferredVideoQuality(String v) =>
      prefs.setString('preferred_video_quality', v);

  /// Cho phép phát âm thanh & AI lồng tiếng trong nền khi khóa màn hình hoặc chuyển app
  bool get backgroundPlayEnabled =>
      prefs.getBool('background_play_enabled') ?? true;
  set backgroundPlayEnabled(bool v) =>
      prefs.setBool('background_play_enabled', v);

  /// Bật chế độ thu nhỏ kiểu YouTube (Mini-player)
  bool get miniPlayerEnabled => prefs.getBool('mini_player_enabled') ?? true;
  set miniPlayerEnabled(bool v) => prefs.setBool('mini_player_enabled', v);

  /// Công cụ dịch bình luận Bilibili: 'local' (Google ML Kit on-device, 0 token API) hoặc 'api' (AI Gemini/Groq)
  String get commentTranslationEngine =>
      prefs.getString('comment_translation_engine') ?? 'local';
  set commentTranslationEngine(String v) =>
      prefs.setString('comment_translation_engine', v);

  // ===== CẤU HÌNH TRỢ LÝ AI HỒNG QUẢ (GEMINI LIVE API) =====
  /// Model Live API mặc định của Trợ lý Hồng Quả
  String get hongguoAssistantModel =>
      prefs.getString('hongguo_assistant_model') ?? 'gemini-3.8-live';
  set hongguoAssistantModel(String v) =>
      prefs.setString('hongguo_assistant_model', v.trim());

  /// Chế độ đầu ra của Trợ lý: false = Chỉ chữ (im lặng), true = Lời nói + chữ
  bool get hongguoAssistantOutputAudio =>
      prefs.getBool('hongguo_assistant_output_audio') ?? false;
  set hongguoAssistantOutputAudio(bool v) =>
      prefs.setBool('hongguo_assistant_output_audio', v);

  /// Số lượng phim gợi ý mặc định của Trợ lý (1..20)
  int get hongguoAssistantDefaultCount =>
      (prefs.getInt('hongguo_assistant_default_count') ?? 5).clamp(1, 20);
  set hongguoAssistantDefaultCount(int v) =>
      prefs.setInt('hongguo_assistant_default_count', v.clamp(1, 20));

  // ===== CẤU HÌNH TRỢ LÝ AI BILIBILI (GEMINI LIVE API) =====
  /// Model Live API mặc định của Trợ lý Bilibili
  String get bilibiliAssistantModel =>
      prefs.getString('bilibili_assistant_model') ?? hongguoAssistantModel;
  set bilibiliAssistantModel(String v) =>
      prefs.setString('bilibili_assistant_model', v.trim());

  /// Chế độ đầu ra của Trợ lý Bilibili: false = Chỉ chữ, true = Lời nói + chữ
  bool get bilibiliAssistantOutputAudio =>
      prefs.getBool('bilibili_assistant_output_audio') ?? false;
  set bilibiliAssistantOutputAudio(bool v) =>
      prefs.setBool('bilibili_assistant_output_audio', v);

  /// Số lượng kết quả gợi ý mặc định của Trợ lý Bilibili (1..20)
  int get bilibiliAssistantDefaultCount =>
      (prefs.getInt('bilibili_assistant_default_count') ?? 5).clamp(1, 20);
  set bilibiliAssistantDefaultCount(int v) =>
      prefs.setInt('bilibili_assistant_default_count', v.clamp(1, 20));

  // ===== CẤU HÌNH NGHE DỊCH TRỰC TIẾP (GEMINI 3.5 LIVE TRANSLATE) =====
  /// Độ trễ bù (AI nghe trước luồng đang phát) tính bằng mili-giây (0..8000ms, mặc định 2000ms).
  int get liveTranslateLeadMs =>
      (prefs.getInt('live_translate_lead_ms') ?? 2000).clamp(0, 8000);
  set liveTranslateLeadMs(int v) =>
      prefs.setInt('live_translate_lead_ms', v.clamp(0, 8000));

  /// Ngôn ngữ đích cho Live Translate (BCP-47, mặc định 'vi').
  String get liveTranslateTargetLanguage =>
      prefs.getString('live_translate_target_language') ?? 'vi';
  set liveTranslateTargetLanguage(String v) => prefs.setString(
    'live_translate_target_language',
    v.trim().isEmpty ? 'vi' : v.trim(),
  );

  /// Có lặp lại câu đã nói bằng ngôn ngữ đích hay không (mặc định false).
  bool get liveTranslateEchoTargetLanguage =>
      prefs.getBool('live_translate_echo_target_language') ?? false;
  set liveTranslateEchoTargetLanguage(bool v) =>
      prefs.setBool('live_translate_echo_target_language', v);

  /// Hiển thị dòng chữ phụ đề live tạm trên video khi nghe dịch trực tiếp.
  bool get liveTranslateShowLiveCaptions =>
      prefs.getBool('live_translate_show_live_captions') ?? true;
  set liveTranslateShowLiveCaptions(bool v) =>
      prefs.setBool('live_translate_show_live_captions', v);

  /// Chờ ngắn (~1.5-2s) lúc mới bật/tua để câu dịch đầu tiên kịp đổ về trước khi chạy video.
  bool get liveTranslatePauseVideoOnWarmup =>
      prefs.getBool('live_translate_pause_video_on_warmup') ?? true;
  set liveTranslatePauseVideoOnWarmup(bool v) =>
      prefs.setBool('live_translate_pause_video_on_warmup', v);

  /// Lọc đoạn im lặng ở máy trước khi gửi lên Live API nhằm tiết kiệm hạn mức 20k TPM.
  bool get liveTranslateVadFilterEnabled =>
      prefs.getBool('live_translate_vad_filter_enabled') ?? true;
  set liveTranslateVadFilterEnabled(bool v) =>
      prefs.setBool('live_translate_vad_filter_enabled', v);

  /// Model dùng cho Nghe Dịch Trực Tiếp.
  String get liveTranslateModel =>
      prefs.getString('live_translate_model') ??
      'gemini-3.5-live-translate-preview';
  set liveTranslateModel(String v) => prefs.setString(
    'live_translate_model',
    v.trim().isEmpty ? 'gemini-3.5-live-translate-preview' : v.trim(),
  );

  // ===== CẤU HÌNH GIAO DIỆN & MÀU SẮC TỪNG TAB =====
  String get uiThemeMode => prefs.getString('ui_theme_mode') ?? 'fresh';
  set uiThemeMode(String v) =>
      prefs.setString('ui_theme_mode', v.trim().isEmpty ? 'fresh' : v.trim());

  String get uiNavStyle => prefs.getString('ui_nav_style') ?? 'floating';
  set uiNavStyle(String v) =>
      prefs.setString('ui_nav_style', v == 'docked' ? 'docked' : 'floating');

  int get uiAccentStudio => prefs.getInt('ui_accent_studio') ?? 0xFF5B5CF6;
  set uiAccentStudio(int v) => prefs.setInt('ui_accent_studio', v);

  int get uiAccentHongguo => prefs.getInt('ui_accent_hongguo') ?? 0xFFFF4D2D;
  set uiAccentHongguo(int v) => prefs.setInt('ui_accent_hongguo', v);

  int get uiAccentBilibili => prefs.getInt('ui_accent_bilibili') ?? 0xFFFB7299;
  set uiAccentBilibili(int v) => prefs.setInt('ui_accent_bilibili', v);

  int get uiAccentHistory => prefs.getInt('ui_accent_history') ?? 0xFF7C3AED;
  set uiAccentHistory(int v) => prefs.setInt('ui_accent_history', v);
}
