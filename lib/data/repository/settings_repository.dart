import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    }
    return _instance!;
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

  String get selectedModel => prefs.getString('selected_model') ?? 'capcut';
  set selectedModel(String v) => prefs.setString('selected_model', v);

  String get selectedGroqModel =>
      prefs.getString('selected_groq_model') ?? 'openai/gpt-oss-120b';
  set selectedGroqModel(String v) =>
      prefs.setString('selected_groq_model', v.trim());

  String get selectedGeminiModel =>
      prefs.getString('selected_gemini_model') ?? 'gemini-3.1-flash-lite';
  set selectedGeminiModel(String v) =>
      prefs.setString('selected_gemini_model', v.trim());

  String get selectedStyle => prefs.getString('selected_style') ?? 'Zhihu';
  set selectedStyle(String v) => prefs.setString('selected_style', v);

  String get defaultSourceLanguage => prefs.getString('source_lang') ?? 'zh-CN';
  set defaultSourceLanguage(String v) => prefs.setString('source_lang', v);

  double get subtitleFontSize =>
      (prefs.getDouble('sub_font_size') ?? 20.0).clamp(5.0, 30.0);
  set subtitleFontSize(double v) =>
      prefs.setDouble('sub_font_size', v.clamp(5.0, 30.0));

  String get selectedFontFamily =>
      prefs.getString('selected_font_family') ?? '';
  set selectedFontFamily(String v) =>
      prefs.setString('selected_font_family', v.trim());

  List<String> get customFonts =>
      prefs.getStringList('custom_fonts') ?? <String>[];
  set customFonts(List<String> v) => prefs.setStringList('custom_fonts', v);

  bool get isBlackBoxEnabled => prefs.getBool('blackbox_enabled') ?? true;
  set isBlackBoxEnabled(bool v) => prefs.setBool('blackbox_enabled', v);

  double get blackBoxHeight => prefs.getDouble('blackbox_height') ?? 64.0;
  set blackBoxHeight(double v) => prefs.setDouble('blackbox_height', v);

  double get blackBoxOpacity => prefs.getDouble('blackbox_opacity') ?? 0.92;
  set blackBoxOpacity(double v) => prefs.setDouble('blackbox_opacity', v);

  double get subtitleOffsetY => prefs.getDouble('sub_offset_y') ?? 0.0;
  set subtitleOffsetY(double v) => prefs.setDouble('sub_offset_y', v);

  String get subtitleColorHex => prefs.getString('sub_color_hex') ?? '#FFFFFF';
  set subtitleColorHex(String v) => prefs.setString('sub_color_hex', v);

  String get subtitleMode => prefs.getString('sub_mode') ?? 'translated';
  set subtitleMode(String v) => prefs.setString('sub_mode', v);

  bool get isTtsPlaybackEnabled =>
      prefs.getBool('tts_playback_enabled') ?? true;
  set isTtsPlaybackEnabled(bool v) => prefs.setBool('tts_playback_enabled', v);

  double get originalVideoVolume =>
      prefs.getDouble('original_video_volume') ?? 0.25;
  set originalVideoVolume(double v) =>
      prefs.setDouble('original_video_volume', v.clamp(0.0, 1.0));

  double get ttsVolume => prefs.getDouble('tts_volume') ?? 1.0;
  set ttsVolume(double v) => prefs.setDouble('tts_volume', v.clamp(0.0, 1.0));

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
      (prefs.getInt('gemini_thread_count') ?? 2).clamp(1, 20);
  set geminiThreadCount(int v) =>
      prefs.setInt('gemini_thread_count', v.clamp(1, 20));

  int get geminiBatchSize =>
      (prefs.getInt('gemini_batch_size') ?? 45).clamp(10, 200);
  set geminiBatchSize(int v) =>
      prefs.setInt('gemini_batch_size', v.clamp(10, 200));

  int get groqThreadCount =>
      (prefs.getInt('groq_thread_count') ?? 3).clamp(1, 20);
  set groqThreadCount(int v) =>
      prefs.setInt('groq_thread_count', v.clamp(1, 20));

  int get groqBatchSize =>
      (prefs.getInt('groq_batch_size') ?? 45).clamp(10, 200);
  set groqBatchSize(int v) =>
      prefs.setInt('groq_batch_size', v.clamp(10, 200));

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
      (prefs.getInt('capcut_stt_concurrency') ?? 3).clamp(1, 20);
  set capcutSttConcurrency(int v) =>
      prefs.setInt('capcut_stt_concurrency', v.clamp(1, 20));

  int get audioSliceConcurrency =>
      (prefs.getInt('audio_slice_concurrency') ?? 3).clamp(1, 20);
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
      prefs.getString('selected_tts_voice') ?? 'ICL_uranus_vi_female_yuenan1';
  set selectedTtsVoice(String v) => prefs.setString('selected_tts_voice', v);

  String get bilibiliSessData => _bilibiliSessData;
  set bilibiliSessData(String v) {
    _bilibiliSessData = v.trim();
    unawaited(
      _secureStorage.write(key: 'bilibili_sessdata', value: _bilibiliSessData),
    );
  }

  int get prefetchEpisodeCount =>
      (prefs.getInt('prefetch_episode_count') ?? 1).clamp(1, 5);
  set prefetchEpisodeCount(int v) =>
      prefs.setInt('prefetch_episode_count', v.clamp(1, 5));

  bool get autoPlayNextEpisode =>
      prefs.getBool('auto_play_next_episode') ?? true;
  set autoPlayNextEpisode(bool v) =>
      prefs.setBool('auto_play_next_episode', v);
}
