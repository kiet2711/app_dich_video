# Architecture Audit (Draft) — CapSub Flutter

> **CẢNH BÁO CHO NGƯỜI VÀ AI ĐỌC TÀI LIỆU**  
> Đây là bản khảo sát/audit, **không phải đặc tả kiến trúc chuẩn (source of truth)**. Không được suy diễn rằng một hành vi đã được xác nhận trên thiết bị nếu mục đó không mang nhãn **ĐÃ XÁC MINH** và không có bằng chứng runtime tương ứng. Chưa dùng tài liệu này để tự động refactor, xoá luồng “trùng”, đổi API hoặc sửa native.

## 1. Thông tin audit

| Mục | Giá trị |
|---|---|
| Repo | `D:\app_ios_apk\capsub_flutter` |
| Nhánh | `feature/hongguo-feed-preview` |
| Commit khảo sát | `80c73c8ba77abdb728aab64ca42ca9686d202a07` |
| Ngày khảo sát | 2026-10-23 |
| Flutter / Dart | Flutter 3.47.5 stable / Dart 3.13.4 |
| Phạm vi | Flutter/Dart, Android Kotlin/Manifest/Gradle, iOS Swift/Info.plist/Podfile, test và cấu hình phụ thuộc |
| Quy mô quan sát | 84 file Dart trong `lib/` (~55.645 dòng), 21 file test (~2.854 dòng), 200 file Git tracked |
| Thay đổi code ứng dụng | Không |

### Nhãn độ tin cậy

- **[ĐÃ XÁC MINH]**: đọc trực tiếp code/cấu hình hoặc lệnh kiểm tra đã chạy thành công tại commit trên.
- **[SUY LUẬN CÓ CƠ SỞ]**: hệ quả hợp lý từ code nhưng chưa tái hiện trên thiết bị/mạng thật.
- **[CHƯA XÁC MINH]**: cần build, thiết bị, tài khoản, dữ liệu hoặc dịch vụ ngoài để kết luận.

Các tham chiếu dạng `path:line` là neo tại commit đã nêu; số dòng có thể trôi sau khi code thay đổi. Tên hàm/lớp nên được ưu tiên khi tìm lại.

## 2. Kết luận điều hành

1. **[ĐÃ XÁC MINH]** Ứng dụng không dùng một framework state management tập trung như Provider/BLoC/Riverpod. Trạng thái được chia giữa `StatefulWidget/setState`, singleton/`ChangeNotifier`, `ValueNotifier`, `SharedPreferences`, file JSON/SRT và các controller media. Các điểm chia sẻ chính là `GlobalPlayerManager`, `SettingsRepository`, notifier tĩnh của `HistoryRepository`/`WatchLaterRepository`, `PipManager` và `PrefetchState`.

2. **[ĐÃ XÁC MINH]** Có **hai kiến trúc phát Hồng Quả cùng tồn tại**:
   - Luồng detail/history/player toàn cục: `GlobalPlayerManager` → `GlobalPlayerOverlay` → `VideoPlayerScreen` → `HongguoPrefetchManager`.
   - Luồng feed dọc: `HongguoFeedScreen` tự sở hữu active/standby `AppPlayerController`, `HongguoStreamProxyServer`, hàng đợi preload/pre-translate và logic TTS riêng.
   Hai luồng dùng các nhóm setting khác nhau và có các đoạn dịch/TTS/lưu history tương tự nhưng không dùng chung hoàn toàn.

3. **[ĐÃ XÁC MINH]** `VideoPlayerScreen` (8.302 dòng) và `HongguoFeedScreen` (6.383 dòng) đang đồng thời gánh UI, lifecycle, network resolution, cache, dịch, TTS, history và orchestration. Đây là các “điểm nóng” cần đọc đầu tiên khi thay đổi hành vi phát video.

4. **[ĐÃ XÁC MINH]** Baseline tại commit khảo sát đang xanh: `flutter analyze` báo `No issues found`; `flutter test` chạy **118 test, tất cả qua**.

5. **[CHƯA XÁC MINH]** Chưa build APK/IPA, chưa chạy emulator/device, chưa đăng nhập Bilibili, chưa gọi các dịch vụ CapCut/Gemini/Groq/Hồng Quả thật, chưa thử DRM, PiP, background playback, SAF/content URI và migration dữ liệu trên thiết bị. Vì vậy audit này chưa chứng minh tính đúng đắn end-to-end.

6. **[ĐÃ XÁC MINH]** Chưa nên tạo `docs/architecture.md` hoặc `AGENTS.md`. Trước hết cần xác minh runtime các nhánh nêu ở mục 13, rồi mới nâng phần đã chắc chắn thành tài liệu chuẩn.

## 3. Phương pháp và giới hạn

### Đã thực hiện

- **[ĐÃ XÁC MINH]** Liệt kê toàn bộ cây file Git, thống kê Dart/test, đọc cấu hình package và native.
- **[ĐÃ XÁC MINH]** Truy vết sâu các luồng entry/navigation, subtitle pipeline, player toàn cục, Hồng Quả detail/feed, Bilibili, TTS, history/cache/settings và platform channels.
- **[ĐÃ XÁC MINH]** Đối chiếu nơi ghi/đọc dữ liệu, endpoint mạng, setting và owner của state.
- **[ĐÃ XÁC MINH]** Chạy analyzer và toàn bộ test hiện có.

### Chưa thực hiện

- **[CHƯA XÁC MINH]** Android/iOS build release và kiểm tra chữ ký/phân phối thực tế.
- **[CHƯA XÁC MINH]** Smoke test trên Android/iOS; đo lifecycle khi app background/foreground/killed.
- **[CHƯA XÁC MINH]** Kiểm thử mạng tích hợp với host ngoài; các endpoint được ghi nhận từ source, không được xác nhận là ổn định hoặc được nhà cung cấp hỗ trợ.
- **[CHƯA XÁC MINH]** Hiệu năng/bộ nhớ khi chạy video dài, feed nhanh, dịch nhiều tập, hoặc cache lớn.
- **[CHƯA XÁC MINH]** Điều khoản sử dụng, bản quyền và tính hợp lệ của việc gọi/scrape các dịch vụ ngoài.

## 4. Bản đồ repo và ranh giới thực tế

| Khu vực | Vai trò quan sát được | Bằng chứng | Trạng thái |
|---|---|---|---|
| `lib/ui/` | Màn hình, widget, nhưng cũng chứa orchestration nghiệp vụ lớn | `lib/ui/player/video_player_screen.dart`, `lib/ui/hongguo/feed/hongguo_feed_screen.dart`, `lib/ui/home/home_screen.dart` | ĐÃ XÁC MINH |
| `lib/player/` | Player dùng `media_kit`, player toàn cục, PiP, TTS scheduler | `lib/player/app_player_controller.dart:58`, `lib/player/global_player_manager.dart:43`, `lib/player/pip_manager.dart:6` | ĐÃ XÁC MINH |
| `lib/domain/pipeline/` | Pipeline media → STT → dịch → SRT/checkpoint | `lib/domain/pipeline/subtitling_pipeline.dart:25`, `:74` | ĐÃ XÁC MINH |
| `lib/domain/media/` | Resolver/download/cache/proxy/prefetch cho Bilibili và Hồng Quả | `bilibili_resolver.dart`, `hongguo_resolver.dart`, `hongguo_prefetch_manager.dart`, `hongguo_stream_proxy_server.dart` | ĐÃ XÁC MINH |
| `lib/domain/ai/` | Chọn model, fallback Gemini/Groq, ML Kit, checkpoint | `smart_ai_translator.dart`, `offline_mlkit_translator.dart`, `translation_checkpoint_manager.dart` | ĐÃ XÁC MINH |
| `lib/domain/tts/` | Sinh/validate/cache giọng đọc | `tts_generation_manager.dart`, `tts_cache_helper.dart`, `audio_file_validator.dart` | ĐÃ XÁC MINH |
| `lib/data/api/` | Client CapCut/Gemini/Groq và signer | `capcut_stt_client.dart`, `capcut_tts_client.dart`, `capcut_vod_uploader.dart`, `gemini_translator.dart`, `groq_translator.dart` | ĐÃ XÁC MINH |
| `lib/data/repository/` | Settings, history, xem sau | `settings_repository.dart`, `history_repository.dart`, `watch_later_repository.dart` | ĐÃ XÁC MINH |
| `lib/data/model/` | Document/subtitle/history/voice/progress models | `subtitle_document.dart`, `subtitle_item.dart`, `history_item.dart` | ĐÃ XÁC MINH |
| `android/` | SAF/media extraction, foreground service, native PiP | `MainActivity.kt`, `AppForegroundService.kt`, `AndroidManifest.xml` | ĐÃ XÁC MINH |
| `ios/` | AVFoundation probe/extract, audio session, notification bridge | `Runner/AppDelegate.swift`, `Runner/Info.plist` | ĐÃ XÁC MINH |

### Ranh giới package không phải Clean Architecture nghiêm ngặt

**[ĐÃ XÁC MINH]** Tên thư mục `data/domain/ui` gợi ý phân lớp, nhưng phụ thuộc thực tế đi hai chiều:

- `domain` gọi trực tiếp `data/api`, `data/model`, `data/repository`, ví dụ `subtitling_pipeline.dart:9-15`, `smart_ai_translator.dart:4-9`.
- `data/repository/history_repository.dart:10-12` gọi ngược `domain/media` và `domain/tts`.
- `data/api/capcut_tts_client.dart:7` gọi validator trong `domain/tts`.
- `domain/media/media_storage.dart:8` import theme trong `ui` để tự hiển thị UI chọn file.

**[SUY LUẬN CÓ CƠ SỞ]** Không nên hướng dẫn AI “tuân theo Clean Architecture hiện có”, vì repo hiện là kiến trúc lai thiên về feature/orchestration, chưa có dependency rule được enforce.

## 5. Sơ đồ runtime cấp cao

```text
main()
  ├─ Flutter binding + MediaKit + PiP + Settings + fonts
  └─ CapSubApp
      └─ MainNavigation (IndexedStack)
          ├─ StudioScreen
          │   ├─ HomeScreen ──> SubtitlingPipeline ──> SubtitleDocument/History
          │   └─ TtsStudioScreen ──> TtsGenerationManager
          ├─ HongguoScreen
          │   ├─ detail ──> GlobalPlayerManager ──> VideoPlayerScreen
          │   │                                  └─ HongguoPrefetchManager
          │   └─ feed ──> HongguoFeedScreen
          │               ├─ active + standby AppPlayerController
          │               ├─ HongguoStreamProxyServer
          │               └─ pre-translate/TTS riêng
          ├─ BilibiliScreen ──> BilibiliResolver ──> Global player
          └─ HistoryScreen ──> HistoryRepository ──> Global player

          GlobalPlayerOverlay (nằm trên toàn bộ IndexedStack)
```

**Bằng chứng:** `lib/main.dart:20`, `:70-94`, `:119-120`; `lib/ui/player/global_player_overlay.dart:7`; `lib/player/global_player_manager.dart:43`.

## 6. Entry, navigation và player toàn cục

### Khởi động

- **[ĐÃ XÁC MINH]** `main()` khởi tạo Flutter binding, cache ảnh, `MediaKit.ensureInitialized()`, `PipManager`, settings/font rồi `runApp`: `lib/main.dart:20-30`.
- **[ĐÃ XÁC MINH]** `MainNavigation` giữ bốn tab trong `IndexedStack`; do đó state của tab được giữ khi chuyển tab: `lib/main.dart:70-120`.
- **[ĐÃ XÁC MINH]** `GlobalPlayerOverlay` được render phủ lên `IndexedStack`, nghe `GlobalPlayerManager` và giữ một `VideoPlayerScreen` theo request: `lib/main.dart:119-120`, `lib/ui/player/global_player_overlay.dart:7-54`.
- **[ĐÃ XÁC MINH]** Nút back Android khi phù hợp gọi native `moveToBack`: `lib/main.dart:113`.

### Global player

- **[ĐÃ XÁC MINH]** `GlobalPlayerManager` là singleton `ChangeNotifier` quản lý `PlaybackRequest` và mode hidden/mini/full: `lib/player/global_player_manager.dart:43`.
- **[ĐÃ XÁC MINH]** Các màn hình TTS, Hồng Quả, Bilibili và History đều có điểm gọi `GlobalPlayerManager.instance.openPlayer`, ví dụ `tts_studio_screen.dart:870`, `hongguo_screen.dart:2434`, `bilibili_screen.dart:429`, `history_screen.dart:649`.
- **[ĐÃ XÁC MINH]** `AppPlayerController` bọc `media_kit` `Player`/`VideoController`, phát local/content URI/remote và hỗ trợ DASH: `lib/player/app_player_controller.dart:58`.
- **[ĐÃ XÁC MINH]** `VideoPlayerScreen` là state owner cho player, subtitle, TTS scheduler, Bilibili metadata/comments, Hồng Quả detail/prefetch, download, PiP và persistence. Các neo chính: `_startOnDemandPipeline` tại `:193`, `_generateTtsForCurrentDocument` tại `:423`, tạo prefetch manager tại `:595/:809`, controller tại `:877`, lưu history tại `:374/:499/:5354`.

## 7. Luồng chức năng chi tiết

### 7.1 Studio: file/link → phụ đề → dịch → history/TTS

1. **[ĐÃ XÁC MINH]** `HomeScreen` chọn file qua `MediaStorage` hoặc nhận URL; URL Bilibili được resolve riêng, URL khác gọi native/media probe: `_probeUrl`, `lib/ui/home/home_screen.dart:302-417`.
2. **[ĐÃ XÁC MINH]** `_startProcessing` dựng `SubtitlingPipeline`, bật wakelock/foreground notification, lắng progress, ghi SRT/JSON dưới Documents `/subtitles`, rồi thêm `HistoryItem`: `home_screen.dart:506`, `:642-704`.
3. **[ĐÃ XÁC MINH]** `SubtitlingPipeline.execute` xác định local/Bilibili/Hồng Quả, dựng canonical checkpoint ID, lấy hoặc tải media/audio, chunk audio, upload VOD + CapCut STT, dịch (CapCut hoặc AI), ghi checkpoint/SRT và dọn temp: `subtitling_pipeline.dart:74-742`.
4. **[ĐÃ XÁC MINH]** Khi hoàn tất, `StudioScreen` có thể chuyển sang TTS Studio thông qua callback giữa hai tab.

```text
local file / generic URL / Bilibili / Hồng Quả
  → probe + duration
  → chuẩn hoá source và checkpoint id
  → lấy video/audio
  → AudioChunker
  → CapCut VOD upload + STT
  → SubtitleDocument
  → CapCut translation hoặc SmartAiTranslator (Gemini/Groq fallback)
  → SRT + .capsub.json + History
  → tuỳ chọn TTS cache
```

### 7.2 Dịch/TTS ngay trong player

- **[ĐÃ XÁC MINH]** `_startOnDemandPipeline` thử load document từ history trước; nếu đã có document thì hiện sub hoặc chỉ sinh TTS, nếu chưa có thì chạy `SubtitlingPipeline`: `video_player_screen.dart:193-421`.
- **[ĐÃ XÁC MINH]** `_generateTtsForCurrentDocument` dùng `TtsGenerationManager`, gắn lại scheduler và lưu document/history: `video_player_screen.dart:423-510`.
- **[ĐÃ XÁC MINH]** Player persist vị trí phát theo identity khác nhau: Hồng Quả ưu tiên series+tập; Bilibili dùng URL/bvid+part; local/khác dùng path/callback: `video_player_screen.dart:5235-5318`, `history_repository.dart:190-207`.

### 7.3 Hồng Quả detail/global player

- **[ĐÃ XÁC MINH]** `HongguoResolver` scrape `hongguoduanju.com`, resolve detail/tập và chọn local engine hoặc Hugging Face engine: `lib/domain/media/hongguo_resolver.dart:97`, `:541`, `:718+`.
- **[ĐÃ XÁC MINH]** `HongguoLocalEngine` gọi API FQ Novel, ký request, chọn quality/codec và có nhánh decrypt/cache cho nội dung mã hoá: `lib/domain/media/hongguo/hongguo_local_engine.dart:55+`.
- **[ĐÃ XÁC MINH]** `VideoPlayerScreen` tạo `HongguoPrefetchManager` khi có `dramaDetail`; manager load history/document hiện có, resolve/cache video, prefetch tập kế và có thể dịch/TTS trước: `video_player_screen.dart:595/:809/:818`; `hongguo_prefetch_manager.dart:43`, `:169`, `:583`.
- **[ĐÃ XÁC MINH]** Luồng này dùng `SettingsRepository.autoPlayNextEpisode` và `prefetchEpisodeCount`: `hongguo_prefetch_manager.dart:209-226`.

### 7.4 Hồng Quả feed dọc

- **[ĐÃ XÁC MINH]** Feed tự tạo active controller 32 MB và standby controller 16 MB, khởi động local stream proxy và swap/preload theo tập: `hongguo_feed_screen.dart:480`, `:535`, `:1031`, `:1201-1494`.
- **[ĐÃ XÁC MINH]** Feed có hàng đợi pre-translation riêng: `_triggerPreTranslationQueue` `:4439`, `_preTranslateSingleEpisode` `:4545`, `_translateCurrentEpisode` `:4958`.
- **[ĐÃ XÁC MINH]** Feed dùng nhóm setting riêng `hongguoAutoNextEpisode`, `hongguoPreTranslateCount`, `hongguoPreTranslateMode`: `hongguo_feed_screen.dart:542-544`; `settings_repository.dart:315-330`.
- **[ĐÃ XÁC MINH]** Feed vẫn có một điểm mở global player tại `hongguo_feed_screen.dart:2276`; vì vậy không được mô tả feed là hoàn toàn tách khỏi global player.

### 7.5 Bilibili

- **[ĐÃ XÁC MINH]** `BilibiliResolver` gom nhiều trách nhiệm: parse URL/part, WBI signing, video details, DASH/muxed streams, subtitle, login QR/profile, danh sách/search/recommendation/comment/uploader/follow: `lib/domain/media/bilibili_resolver.dart` (2.136 dòng).
- **[ĐÃ XÁC MINH]** `BilibiliScreen` mở video vào global player: `bilibili_screen.dart:429`.
- **[ĐÃ XÁC MINH]** Pipeline ưu tiên subtitle có sẵn trừ khi setting yêu cầu CapCut; nếu không, tải audio/video rồi STT: `subtitling_pipeline.dart:151-319`.
- **[CHƯA XÁC MINH]** Login cookie, WBI, DASH, subtitle và endpoint list/search chưa được kiểm thử với tài khoản/mạng thật trong audit này.

### 7.6 History và dữ liệu phụ đề

- **[ĐÃ XÁC MINH]** Metadata history là JSON list trong SharedPreferences key `capsub_history`: `history_repository.dart:15-25`.
- **[ĐÃ XÁC MINH]** `saveHistory` ghi SRT và `.capsub.json` vào Documents `/saved_subtitles`: `history_repository.dart:226-256`.
- **[ĐÃ XÁC MINH]** Luồng Studio ban đầu ghi Documents `/subtitles` rồi `addItem`, còn player/prefetch/feed thường gọi `saveHistory`: `home_screen.dart:642-704`; `video_player_screen.dart:374/:499`; `hongguo_prefetch_manager.dart:754-756`; `hongguo_feed_screen.dart:4707-4708`.
- **[ĐÃ XÁC MINH]** Repository có migration/self-heal đường dẫn iOS, fallback từ `.capsub.json` sang SRT, backup/restore subtitle và cleanup cache liên quan: `history_repository.dart:32-129`, `:313-489`, `:823-1027`.

## 8. State management và ownership

| State | Owner/cơ chế | Nơi dùng chính | Trạng thái |
|---|---|---|---|
| Tab hiện tại | `MainNavigation` + `setState` | `lib/main.dart` | ĐÃ XÁC MINH |
| Player toàn cục + display mode | singleton `GlobalPlayerManager` (`ChangeNotifier`) | overlay và nhiều màn hình | ĐÃ XÁC MINH |
| Playback engine | `AppPlayerController` (`ChangeNotifier`) | global player và feed | ĐÃ XÁC MINH |
| PiP | singleton-ish `PipManager`, `ValueNotifier` + MethodChannel | Android/global player | ĐÃ XÁC MINH |
| Settings | singleton `SettingsRepository` + SharedPreferences/SecureStorage | toàn app | ĐÃ XÁC MINH |
| History | repository instance mới mỗi `getInstance`, dữ liệu chung trong prefs; notifier tĩnh | History/player/pipeline/prefetch | ĐÃ XÁC MINH |
| Watch later | repository instance mới + notifier tĩnh | Bilibili/Hồng Quả/player | ĐÃ XÁC MINH |
| Subtitle/TTS/player UI | state cục bộ trong `VideoPlayerScreen` | global player | ĐÃ XÁC MINH |
| Feed paging/player/preload/translation | state cục bộ trong `HongguoFeedScreen` | feed | ĐÃ XÁC MINH |
| Hồng Quả detail prefetch | `HongguoPrefetchManager` + `PrefetchState` | `VideoPlayerScreen` | ĐÃ XÁC MINH |
| Translation checkpoint | file JSON theo session key | pipeline/AI translator | ĐÃ XÁC MINH |

**[SUY LUẬN CÓ CƠ SỞ]** Vì state nghiệp vụ lớn nằm trong widget và có nhiều lệnh async, rủi ro race/stale response chủ yếu tập trung ở feed/player. Feed đã có request/generation guard ở một số nhánh, nhưng chưa có mô hình state machine dùng chung để chứng minh mọi transition đều hợp lệ.

## 9. Persistence, cache và bí mật

| Dữ liệu | Nơi lưu | Bằng chứng | Trạng thái |
|---|---|---|---|
| Settings thông thường | SharedPreferences | `settings_repository.dart:9-23` | ĐÃ XÁC MINH |
| Gemini/Groq API keys, Bilibili SESSDATA | `FlutterSecureStorage` | `settings_repository.dart:8`, `:26-38`, `:219` | ĐÃ XÁC MINH |
| Bilibili `bili_jct` | SharedPreferences | `settings_repository.dart:223-224` | ĐÃ XÁC MINH |
| History metadata | SharedPreferences `capsub_history` | `history_repository.dart:15-25` | ĐÃ XÁC MINH |
| Watch later | SharedPreferences `capsub_watch_later` | `watch_later_repository.dart:6-18` | ĐÃ XÁC MINH |
| Subtitle chuẩn của `saveHistory` | Documents `/saved_subtitles` | `history_repository.dart:226-256` | ĐÃ XÁC MINH |
| Studio output ban đầu | Documents `/subtitles` | `home_screen.dart:642-657` | ĐÃ XÁC MINH |
| TTS cache chuẩn | Documents `/tts_cache/<docKey>/<voiceType>` | `tts_cache_helper.dart:32-41` | ĐÃ XÁC MINH |
| TTS legacy | Documents `/tts_cache_<voiceType>` | `tts_cache_helper.dart:78-79`, `tts_generation_manager.dart:114-135` | ĐÃ XÁC MINH |
| Video cache | Application Support `/video_cache` | `video_cache_manager.dart:21-22` | ĐÃ XÁC MINH |
| Media import | Application Support `/media` | `media_storage.dart:276+` | ĐÃ XÁC MINH |
| Translation checkpoint | Documents `/translation_checkpoints` | `translation_checkpoint_manager.dart:120-124` | ĐÃ XÁC MINH |
| Pipeline session | Temporary `/sub_session_*` | `subtitling_pipeline.dart:96-100` | ĐÃ XÁC MINH |

**[SUY LUẬN CÓ CƠ SỞ]** Việc tồn tại cả `/subtitles` và `/saved_subtitles`, cùng TTS cache chuẩn và legacy, làm tăng chi phí cleanup/migration và khiến AI dễ nhầm một đường dẫn là duy nhất. Không hợp nhất/xoá trước khi có test migration dữ liệu thật.

## 10. Dịch vụ ngoài và API surface

| Host/nhóm | Mục đích quan sát được | Credential/cơ chế | Bằng chứng | Trạng thái |
|---|---|---|---|---|
| `editor-api-sg.capcutapi.com` | VOD upload, STT, TTS/translation liên quan | custom signing/device config | `capcut_signer.dart:16`, clients trong `lib/data/api/` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |
| `generativelanguage.googleapis.com` | Gemini translation/key check/title | API key | `gemini_translator.dart:672`, `gemini_key_checker.dart:90` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |
| `api.groq.com` | Groq translation/key check/title | Bearer API key | `groq_translator.dart:417`, `groq_key_checker.dart:86` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |
| `api.bilibili.com` | details, streams, subtitle, search/list/comment/follow | WBI/cookie/SESSDATA/CSRF tuỳ API | `bilibili_resolver.dart:570-2115` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |
| `passport.bilibili.com` | web/QR login | cookie | `bilibili_login_sheet.dart:143`, `bilibili_resolver.dart:1302-1319` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |
| `hongguoduanju.com` | browse/search/detail/public player | scrape HTML/public link | `hongguo_resolver.dart:97`, feed `:3503` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |
| `kietno1-hongqua.hf.space` | fallback resolve Hồng Quả | Gradio API | `hongguo_resolver.dart:541+` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |
| `api5-normal-sinfonlineb.fqnovel.com` | lấy model/stream Hồng Quả | local signing + decode/decrypt | `hongguo_local_engine.dart:55+` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |
| ML Kit / MyMemory | dịch offline/fallback text | model on-device / HTTP fallback | `offline_mlkit_translator.dart` | ĐÃ XÁC MINH trong source; runtime CHƯA XÁC MINH |

**[SUY LUẬN CÓ CƠ SỞ]** Một số tích hợp dựa trên endpoint web/private-like, signing hoặc scrape nên có độ giòn cao khi bên thứ ba đổi schema/chống bot. Cần contract test hoặc telemetry lỗi trước khi mô tả chúng là “ổn định”.

## 11. Native Android/iOS và khác biệt nền tảng

### Android

- **[ĐÃ XÁC MINH]** `com.capcut.capsub/media`: SAF picker, copy content URI, metadata/probe, extract audio, move app về background: `MainActivity.kt:32`, `:153+`, `:330+`.
- **[ĐÃ XÁC MINH]** `com.capcut.capsub/foreground_service`: start/update/stop `AppForegroundService`: `MainActivity.kt:33`, `:216+`.
- **[ĐÃ XÁC MINH]** Service giữ partial wakelock tối đa 30 phút và khai báo dataSync/mediaPlayback: `AppForegroundService.kt:25-26`, `:54-61`.
- **[ĐÃ XÁC MINH]** `com.capcut.capsub/pip`: native PiP và callback play/pause/seek/mode: `MainActivity.kt:34`, `:242-316`.
- **[ĐÃ XÁC MINH]** Manifest bật PiP, foreground permissions, `usesCleartextTraffic=true`: `AndroidManifest.xml:7-9`, `:17`, `:29`.

### iOS

- **[ĐÃ XÁC MINH]** `AppDelegate` cấu hình `AVAudioSession` playback/mix/bluetooth: `ios/Runner/AppDelegate.swift:11-20`.
- **[ĐÃ XÁC MINH]** Media channel chỉ implement `probeMedia` và `extractAudio`: `AppDelegate.swift:36-69`.
- **[ĐÃ XÁC MINH]** Foreground channel trên iOS chỉ tạo/xoá local notification; không khởi tạo background task tương đương Android service: `AppDelegate.swift:72-116`.
- **[ĐÃ XÁC MINH]** Không có handler native cho channel PiP trong iOS source đã khảo sát; `PipManager` phía Dart dùng channel `com.capcut.capsub/pip`: `lib/player/pip_manager.dart:7`.
- **[ĐÃ XÁC MINH]** `Info.plist` khai báo background audio và `NSAllowsArbitraryLoads`; deployment target là iOS 15.5: `Info.plist:29-37`, `Podfile:2/:44`.

### Ma trận parity hiện thấy

| Khả năng | Android | iOS | Trạng thái |
|---|---|---|---|
| Chọn media native/persistable URI | SAF channel | Dart `file_picker` + copy | ĐÃ XÁC MINH từ code |
| Probe/extract audio native | Kotlin Media APIs | AVFoundation | ĐÃ XÁC MINH từ code |
| Foreground work | Foreground service + wakelock | Local notification bridge | ĐÃ XÁC MINH từ code; độ sống nền CHƯA XÁC MINH |
| Native PiP | Có | Không thấy implementation | ĐÃ XÁC MINH từ source; runtime CHƯA XÁC MINH |
| Background audio config | foreground/media playback | `UIBackgroundModes` audio + AVAudioSession | ĐÃ XÁC MINH từ config |

## 12. Dependency và test baseline

### Dependency đáng chú ý

- **[ĐÃ XÁC MINH]** Player chính dùng `media_kit`, `media_kit_video`, `media_kit_libs_video`; TTS playback dùng `just_audio`: `pubspec.yaml:48`, `:55-57` và các import trong `app_player_controller.dart`, `tts_audio_scheduler.dart`.
- **[ĐÃ XÁC MINH]** Network chủ yếu dùng `dio`; local persistence dùng `shared_preferences`, `flutter_secure_storage`, `path_provider`.
- **[ĐÃ XÁC MINH]** Có dependency `video_player: ^2.14.0` trong `pubspec.yaml:43`, nhưng không tìm thấy import trực tiếp `package:video_player/...` trong `lib/` hoặc `test/` tại commit này.
- **[SUY LUẬN CÓ CƠ SỞ]** `video_player` là ứng viên dependency thừa, nhưng chỉ nên xoá sau khi kiểm tra plugin registration/build cả hai nền tảng và lockfile.

### Test hiện có

- **[ĐÃ XÁC MINH]** 21 file test, 118 test pass. Các vùng có test: model registry, audio chunking/validation, CapCut signer, Gemini/Groq/key checker, Smart AI fallback, History/migration/resume, Hồng Quả prefetch selection, settings/subtitle customization, TTS scheduler/generation/error dialog, pipeline Bilibili mode và foreground manager trên non-Android.
- **[ĐÃ XÁC MINH]** Analyzer pass không cảnh báo.
- **[CHƯA XÁC MINH]** Không thấy `integration_test/` trong danh sách file khảo sát. Chưa có bằng chứng tự động cho navigation end-to-end, player thật, proxy, PiP, background lifecycle, native extraction trên thiết bị, DRM, login/cookie, cache eviction và schema ngoài.

## 13. Phát hiện cần ưu tiên xác minh

### F-01 — Hai hệ Hồng Quả chồng chéo

- **Mức:** Cao cho bảo trì; chưa kết luận là bug.
- **Trạng thái:** **[ĐÃ XÁC MINH]** về cấu trúc.
- **Bằng chứng:** global/detail dùng `VideoPlayerScreen` + `HongguoPrefetchManager`; feed dùng controller/proxy/pretranslate riêng. Setting cũng tách thành `autoPlayNextEpisode/prefetchEpisodeCount` và `hongguoAutoNextEpisode/hongguoPreTranslate*`.
- **Hệ quả:** **[SUY LUẬN CÓ CƠ SỞ]** sửa một luồng có thể không sửa luồng còn lại; history/cache/TTS có thể lệch hành vi.
- **Không được làm vội:** không xoá một luồng là “duplicate” trước khi lập ma trận UX và test parity.

### F-02 — Setting background play bị ép `true` khi player khởi tạo

- **Mức:** Cao về tính đúng của setting.
- **Trạng thái:** **[ĐÃ XÁC MINH]** trong code.
- **Bằng chứng:** `video_player_screen.dart:775` gán `_settings.backgroundPlayEnabled = true` ngay sau khi load settings; repository vẫn có getter/setter ở `settings_repository.dart:442-444`.
- **Hệ quả:** **[SUY LUẬN CÓ CƠ SỞ]** lựa chọn tắt của người dùng có thể bị ghi đè khi mở player.
- **Cần test:** tắt trong Settings → mở/đóng player → background app → kiểm tra setting và audio trên Android/iOS.

### F-03 — URL probe có thể báo “sẵn sàng” với duration = 0 nhưng pipeline từ chối

- **Mức:** Cao cho link online khó probe.
- **Trạng thái:** **[ĐÃ XÁC MINH]** về hai nhánh code; runtime **[CHƯA XÁC MINH]**.
- **Bằng chứng:** catch của `_probeUrl` lưu `_fileDurationMs = 0` và message “sẵn sàng” tại `home_screen.dart:400-415`; `SubtitlingPipeline.execute` ném lỗi khi `totalDurationMs <= 0` tại `subtitling_pipeline.dart:85-91`.
- **Hệ quả:** **[SUY LUẬN CÓ CƠ SỞ]** người dùng được phép bấm bắt đầu nhưng xử lý thất bại ngay.

### F-04 — Pre-translate Hồng Quả dùng duration cố định 120 giây

- **Mức:** Trung bình–cao.
- **Trạng thái:** **[ĐÃ XÁC MINH]** hằng số; ảnh hưởng **[SUY LUẬN CÓ CƠ SỞ]**.
- **Bằng chứng:** feed `hongguo_feed_screen.dart:4663/:4713`; detail prefetch `hongguo_prefetch_manager.dart:724/:760`.
- **Hệ quả dự kiến:** tập ngắn/dài hơn có thể tạo progress, slicing, history duration hoặc phạm vi STT không khớp media thật.
- **Cần test:** tập <2 phút, =2 phút, >2 phút; so câu cuối, seek, progress và resume.

### F-05 — Release Android đang dùng debug signing config

- **Mức:** Chặn phát hành nếu đây là cấu hình production.
- **Trạng thái:** **[ĐÃ XÁC MINH]**.
- **Bằng chứng:** `android/app/build.gradle.kts:37` dùng `signingConfigs.getByName("debug")`; application id tại `:20` là `com.capcut.capsub_flutter`.
- **Lưu ý:** không đổi trong audit; cần quyết định release process/keystore riêng.

### F-06 — Network policy quá rộng

- **Mức:** Trung bình–cao về bảo mật/compliance.
- **Trạng thái:** **[ĐÃ XÁC MINH]** cấu hình.
- **Bằng chứng:** Android `usesCleartextTraffic=true` (`AndroidManifest.xml:17`); iOS `NSAllowsArbitraryLoads` (`Info.plist:37`).
- **Hệ quả:** **[SUY LUẬN CÓ CƠ SỞ]** app cho phép traffic không TLS/rộng hơn cần thiết; chưa chứng minh có request HTTP nhạy cảm.
- **Cần làm sau:** inventory host/proxy thật rồi giới hạn exception theo domain nếu khả thi.

### F-07 — Ranh giới layer yếu và widget “god object”

- **Mức:** Cao cho thay đổi dài hạn.
- **Trạng thái:** **[ĐÃ XÁC MINH]**.
- **Bằng chứng:** `VideoPlayerScreen` 8.302 dòng; `HongguoFeedScreen` 6.383; `HistoryScreen` 4.281; dependency hai chiều ở mục 4.
- **Hệ quả:** **[SUY LUẬN CÓ CƠ SỞ]** AI hoặc người sửa theo tên folder dễ bỏ sót side effect nằm trong UI.
- **Khuyến nghị tài liệu:** bản kiến trúc cuối phải mô tả owner theo **luồng runtime**, không chỉ theo folder.

### F-08 — Hai chiến lược ghi subtitle/history

- **Mức:** Trung bình.
- **Trạng thái:** **[ĐÃ XÁC MINH]**.
- **Bằng chứng:** Studio ghi `/subtitles` + `addItem`; các luồng khác dùng `saveHistory` → `/saved_subtitles`.
- **Hệ quả:** **[SUY LUẬN CÓ CƠ SỞ]** cleanup/migration/backup có thể không đồng nhất giữa item tạo từ Studio và item tạo trong player/feed.
- **Cần test:** tạo, sửa, restore, xoá cùng một loại video từ cả hai entry point.

### F-09 — Checkpoint key hiển thị ở Home có dấu hiệu không trùng key pipeline Bilibili

- **Mức:** Trung bình.
- **Trạng thái:** canonical ID khác nhau **[ĐÃ XÁC MINH]**; lỗi UX **[SUY LUẬN CÓ CƠ SỞ]**.
- **Bằng chứng:** Home probe tạo key từ canonical URL ở `home_screen.dart:370-381`; pipeline đổi sang ID Bilibili riêng ở `subtitling_pipeline.dart:109-137`.
- **Hệ quả dự kiến:** Home có thể không hiện thông báo draft dù pipeline vẫn tự resume bằng key nội bộ.
- **Cần test:** dừng giữa chừng part 1/part 2, restart app, probe lại và resume.

### F-10 — Native parity không đồng nghĩa

- **Mức:** Trung bình–cao.
- **Trạng thái:** **[ĐÃ XÁC MINH]** từ source.
- **Bằng chứng:** Android có foreground service + wakelock + native PiP; iOS bridge chỉ notification, probe/extract và audio background config.
- **Hệ quả:** **[SUY LUẬN CÓ CƠ SỞ]** cùng tên manager ở Dart có thể tạo kỳ vọng sai rằng hành vi background/PiP tương đương.

### F-11 — Credential có mức bảo vệ khác nhau

- **Mức:** Trung bình.
- **Trạng thái:** **[ĐÃ XÁC MINH]**.
- **Bằng chứng:** API keys và SESSDATA dùng SecureStorage; `bili_jct` dùng SharedPreferences (`settings_repository.dart:223-224`).
- **Hệ quả:** **[SUY LUẬN CÓ CƠ SỞ]** CSRF token có thể bị lộ trong backup/log/debug extraction dễ hơn cookie bảo mật. Cần threat model trước khi đổi format/migration.

### F-12 — Dịch vụ ngoài là điểm lỗi kiến trúc quan trọng

- **Mức:** Cao cho độ ổn định sản phẩm.
- **Trạng thái:** **[ĐÃ XÁC MINH]** về phụ thuộc; SLA/độ ổn định **[CHƯA XÁC MINH]**.
- **Bằng chứng:** CapCut signing/VOD/STT/TTS, Bilibili WBI/cookie, Hồng Quả scrape/local signer/HF fallback, Gemini/Groq quota.
- **Khuyến nghị:** tài liệu chuẩn phải phân biệt “official public API”, “web endpoint/scrape”, “fallback riêng”, cùng failure/fallback path; không gộp thành một hộp `API` chung.

## 14. Những điều chưa được phép kết luận

- **[CHƯA XÁC MINH]** Luồng nào trong hai luồng Hồng Quả là “mới”, “cũ”, “chuẩn” hoặc có thể xoá.
- **[CHƯA XÁC MINH]** App tiếp tục dịch/phát ổn định khi background quá 30 phút trên Android hoặc bị iOS suspend.
- **[CHƯA XÁC MINH]** PiP hoạt động đúng trên mọi Android API được hỗ trợ; iOS không có native PiP chỉ được kết luận từ source hiện thấy.
- **[CHƯA XÁC MINH]** Cache/decrypt Hồng Quả đúng với mọi variant DRM/codec.
- **[CHƯA XÁC MINH]** Bilibili login/follow/comment/search hoạt động với cookie thật và thay đổi API hiện tại.
- **[CHƯA XÁC MINH]** Mọi history cũ có thể migrate; unit test chỉ bao phủ fixture đã viết.
- **[CHƯA XÁC MINH]** Xoá `video_player`, hợp nhất cache hoặc đổi repository thành singleton là an toàn.

## 15. Kế hoạch đối chiếu trước khi tạo `architecture.md` / `AGENTS.md`

### Gate A — Runtime smoke test bắt buộc

1. Android: local file qua SAF, generic URL, Bilibili part/DASH, Hồng Quả detail và feed.
2. iOS: file picker/copy, probe/extract, background audio, notification, lifecycle resume.
3. Với mỗi source: tạo sub, dừng/resume checkpoint, dịch, TTS, seek, đổi speed/volume, download/cache, mở lại từ History, xoá và kiểm tra cleanup.
4. Hồng Quả: so sánh cùng một series/tập qua detail/global player và feed; kiểm tra hai bộ setting.
5. PiP/background: app foreground → PiP/background → return → kill/relaunch.

### Gate B — Contract/failure tests

- Mỗi host ngoài có test success, timeout, 401/403, 429, 5xx, schema thiếu field và fallback.
- Bilibili: anonymous/login, single/multipart, subtitle có/không, DASH fallback.
- Hồng Quả: public web, local engine, HF fallback, encrypted/decrypted, cache hit/miss.
- AI: key chết, quota, rotate model/provider, checkpoint resume.

### Gate C — Xác nhận với chủ repo

- Luồng UX nào là canonical cho Hồng Quả.
- Ý nghĩa mong muốn của background play/PiP trên từng nền tảng.
- Chính sách lưu/xoá media và lịch sử; dữ liệu nào phải survive update/reinstall.
- API nào được phép dùng trong production và release signing/application id mong muốn.

### Gate D — Chỉ sau A–C mới viết tài liệu chuẩn

- `docs/architecture.md`: chỉ đưa phần **ĐÃ XÁC MINH** và quyết định đã được chủ repo chấp thuận.
- `AGENTS.md`: chỉ ghi guardrail ngắn, có thể kiểm tra được; liên kết tới architecture; không nhét suy luận hoặc roadmap vào instruction.
- Mỗi claim quan trọng nên có test/owner và ngày xác minh; mục phụ thuộc ngoài cần ghi failure/fallback.

## 16. Đề xuất cấu trúc tài liệu chuẩn sau này (chưa tạo)

1. System context và platform support.
2. Runtime entry/navigation/global overlay.
3. Source adapters: local/generic URL/Bilibili/Hồng Quả.
4. Subtitle pipeline và checkpoint identity.
5. Playback architectures: global player vs Hồng Quả feed.
6. State ownership và async lifecycle.
7. Persistence/cache/migration/cleanup.
8. Native channel contract và parity matrix.
9. External API contract/fallback/security.
10. Test gates và “safe change checklist” cho AI.

## 17. Nhật ký kiểm tra

| Kiểm tra | Kết quả | Trạng thái |
|---|---|---|
| `flutter analyze` | `No issues found!` | ĐÃ XÁC MINH |
| `flutter test` | 118 test pass | ĐÃ XÁC MINH |
| Git status trước/sau khảo sát code | Sạch trước khi thêm tài liệu | ĐÃ XÁC MINH |
| Android build | Không chạy | CHƯA XÁC MINH |
| iOS build | Không chạy | CHƯA XÁC MINH |
| Device/E2E/network | Không chạy | CHƯA XÁC MINH |

---

**Quy tắc sử dụng bản nháp:** nếu code và tài liệu mâu thuẫn, ưu tiên code + test/runtime evidence. Nếu một mục chỉ là **SUY LUẬN** hoặc **CHƯA XÁC MINH**, AI phải nêu lại giả định và xin/xây dựng bằng chứng trước khi thay đổi kiến trúc.
