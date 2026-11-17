import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'hongguo_auth_service.dart';
import 'hongguo_device_service.dart';
import 'hongguo_sixgod_signer.dart';
import 'hongguo_v5_constants.dart';

class HongguoCloudProfile {
  final String bizUserId;
  final String userName;
  final String avatarUrl;

  const HongguoCloudProfile({
    required this.bizUserId,
    required this.userName,
    this.avatarUrl = '',
  });
}

class HongguoCloudProgress {
  final String seriesId;
  final String title;
  final String cover;
  final String badge;
  final int totalEpisodes;
  final String episodeId;
  final int episodeIndex; // 1-based trong toàn bộ UI capsub_flutter
  final int positionMs;
  final int durationMs;
  final int updatedAtMs;

  const HongguoCloudProgress({
    required this.seriesId,
    this.title = '',
    this.cover = '',
    this.badge = '',
    this.totalEpisodes = 0,
    required this.episodeId,
    required this.episodeIndex,
    required this.positionMs,
    this.durationMs = 0,
    required this.updatedAtMs,
  });

  HongguoCloudProgress copyWith({
    String? title,
    String? cover,
    String? badge,
    int? totalEpisodes,
  }) {
    return HongguoCloudProgress(
      seriesId: seriesId,
      title: title ?? this.title,
      cover: cover ?? this.cover,
      badge: badge ?? this.badge,
      totalEpisodes: totalEpisodes ?? this.totalEpisodes,
      episodeId: episodeId,
      episodeIndex: episodeIndex,
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAtMs: updatedAtMs,
    );
  }
}

class HongguoCloudFavorite {
  final String seriesId;
  final String title;
  final String cover;
  final String badge;
  final int totalEpisodes;

  const HongguoCloudFavorite({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.badge = '',
    this.totalEpisodes = 0,
  });
}

class HongguoCloudReservation {
  final String seriesId;
  final String title;
  final String cover;
  final String badge;
  final bool isOnline;
  final String releaseTimeText;

  const HongguoCloudReservation({
    required this.seriesId,
    required this.title,
    this.cover = '',
    this.badge = '',
    required this.isOnline,
    this.releaseTimeText = '',
  });
}

class HongguoCloudAccountState {
  final int generation;
  final HongguoAccountCredentials? credentials;
  final HongguoCloudProfile? profile;
  final List<HongguoCloudProgress> history;
  final List<HongguoCloudFavorite> favorites;
  final Set<String> favoritePendingIds;
  final List<HongguoCloudReservation> onlineReservations;
  final List<HongguoCloudReservation> upcomingReservations;
  final String? onlineReservationsError;
  final String? upcomingReservationsError;
  final bool isLoading;
  final String? lastError;

  const HongguoCloudAccountState({
    this.generation = 0,
    this.credentials,
    this.profile,
    this.history = const <HongguoCloudProgress>[],
    this.favorites = const <HongguoCloudFavorite>[],
    this.favoritePendingIds = const <String>{},
    this.onlineReservations = const <HongguoCloudReservation>[],
    this.upcomingReservations = const <HongguoCloudReservation>[],
    this.onlineReservationsError,
    this.upcomingReservationsError,
    this.isLoading = false,
    this.lastError,
  });

  bool get isLoggedIn => credentials?.isValid == true;

  bool isFavorite(String seriesId) =>
      favorites.any((f) => f.seriesId == seriesId);

  bool isFavoritePending(String seriesId) =>
      favoritePendingIds.contains(seriesId);

  HongguoCloudProgress? progressForSeries(String seriesId) {
    for (final p in history) {
      if (p.seriesId == seriesId) return p;
    }
    return null;
  }

  HongguoCloudAccountState copyWith({
    int? generation,
    HongguoAccountCredentials? credentials,
    bool clearCredentials = false,
    HongguoCloudProfile? profile,
    bool clearProfile = false,
    List<HongguoCloudProgress>? history,
    List<HongguoCloudFavorite>? favorites,
    Set<String>? favoritePendingIds,
    List<HongguoCloudReservation>? onlineReservations,
    List<HongguoCloudReservation>? upcomingReservations,
    String? onlineReservationsError,
    bool clearOnlineError = false,
    String? upcomingReservationsError,
    bool clearUpcomingError = false,
    bool? isLoading,
    String? lastError,
    bool clearError = false,
  }) {
    return HongguoCloudAccountState(
      generation: generation ?? this.generation,
      credentials:
          clearCredentials ? null : (credentials ?? this.credentials),
      profile: clearProfile ? null : (profile ?? this.profile),
      history: history ?? this.history,
      favorites: favorites ?? this.favorites,
      favoritePendingIds: favoritePendingIds ?? this.favoritePendingIds,
      onlineReservations: onlineReservations ?? this.onlineReservations,
      upcomingReservations: upcomingReservations ?? this.upcomingReservations,
      onlineReservationsError: clearOnlineError
          ? null
          : (onlineReservationsError ?? this.onlineReservationsError),
      upcomingReservationsError: clearUpcomingError
          ? null
          : (upcomingReservationsError ?? this.upcomingReservationsError),
      isLoading: isLoading ?? this.isLoading,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }
}

/// Quản lý đồng bộ tài khoản đám mây Hồng Quả (`CloudAccount.kt` & `AccountController.kt`):
/// - Hồ sơ tài khoản (kiểm tra bắt buộc `biz_user_id`, tránh nhầm phiên ẩn danh).
/// - Lịch sử xem đám mây 50 mục + đồng bộ siêu dữ liệu qua `/reading/bookapi/multi-detail/v1/`.
/// - Tủ phim yêu thích 2 chiều kèm đọc kiểm chứng sau khi ghi (`/bookshelf/video/update/v1/` -> `info/v1/`).
/// - Danh sách đặt trước (`is_online=true` và `is_online=false` tách biệt).
/// - Đẩy tiến độ xem lên cloud có debounce 15 giây (`/read_progress/upload/v1/`).
class HongguoCloudAccountService {
  HongguoCloudAccountService._();
  static final HongguoCloudAccountService instance =
      HongguoCloudAccountService._();

  static const String apiBase = 'https://api5-normal-sinfonlinea.fqnovel.com';
  static final RegExp _numericIdRegex = RegExp(r'^[0-9]{1,30}$');

  final ValueNotifier<HongguoCloudAccountState> state =
      ValueNotifier<HongguoCloudAccountState>(
    const HongguoCloudAccountState(),
  );

  Dio? _overrideDio;
  final Dio _defaultDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 15),
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  Timer? _debounceTimer;
  HongguoCloudProgress? _pendingUpload;
  int _pendingUploadEpisodeCount = 0;
  String? _lastUploadedSignature;

  Dio get _dio => _overrideDio ?? _defaultDio;

  @visibleForTesting
  void setDioForTesting(Dio? dio) {
    _overrideDio = dio;
  }

  @visibleForTesting
  void resetForTesting() {
    _overrideDio = null;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingUpload = null;
    _lastUploadedSignature = null;
    state.value = const HongguoCloudAccountState();
  }

  /// Khôi phục phiên đăng nhập khi khởi động app / mở trang Hồng Quả.
  Future<void> initialize() async {
    final gen = state.value.generation;
    final creds = await HongguoAuthService.instance.loadCredentials();
    if (gen != state.value.generation || creds == null || !creds.isValid) {
      return;
    }
    state.value = state.value.copyWith(credentials: creds);
    await refreshAll();
  }

  Future<void> onLoginSucceeded(HongguoAccountCredentials credentials) async {
    final nextGen = state.value.generation + 1;
    state.value = HongguoCloudAccountState(
      generation: nextGen,
      credentials: credentials,
      isLoading: true,
    );
    await refreshAll();
  }

  Future<void> logout() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingUpload = null;
    _lastUploadedSignature = null;
    await HongguoAuthService.instance.clearCredentials();
    state.value = HongguoCloudAccountState(
      generation: state.value.generation + 1,
    );
  }

  Future<void> refreshAll() async {
    final gen = state.value.generation;
    final creds = state.value.credentials;
    if (creds == null || !creds.isValid) return;

    state.value = state.value.copyWith(isLoading: true, clearError: true);
    try {
      final profile = await fetchProfile(creds);
      if (gen != state.value.generation) return;
      state.value = state.value.copyWith(profile: profile);
    } catch (e) {
      if (gen != state.value.generation) return;
      final isNotProvisioned = e is HongguoAccountNotProvisionedException;
      state.value = state.value.copyWith(
        isLoading: !isNotProvisioned,
        lastError: _sanitizeError(e),
      );
      if (isNotProvisioned) return;
    }

    await Future.wait<void>(<Future<void>>[
      refreshHistory().catchError((_) => const <HongguoCloudProgress>[]),
      refreshFavorites().catchError((_) => const <HongguoCloudFavorite>[]),
      refreshReservations().catchError((_) {}),
    ]);
    if (gen == state.value.generation) {
      state.value = state.value.copyWith(isLoading: false);
    }
  }

  // ==================== HỒ SƠ ====================

  Future<HongguoCloudProfile> fetchProfile([
    HongguoAccountCredentials? explicitCreds,
  ]) async {
    final creds = explicitCreds ?? state.value.credentials;
    if (creds == null || !creds.isValid) {
      throw const HongguoAuthException('Chưa đăng nhập tài khoản Hồng Quả');
    }
    final raw = await _signedRequest(creds, '/reading/user/info/v1/');
    final data = raw['data'];
    if (data is! Map) {
      throw const HongguoAuthException('Hồ sơ tài khoản trống');
    }
    final bizId = data['biz_user_id']?.toString().trim() ?? '';
    if (bizId.isEmpty) {
      throw const HongguoAccountNotProvisionedException();
    }
    return HongguoCloudProfile(
      bizUserId: bizId,
      userName: data['user_name']?.toString() ??
          data['nick_name']?.toString() ??
          'Tài khoản Hồng Quả',
      avatarUrl: data['avatar_url']?.toString() ?? '',
    );
  }

  // ==================== LỊCH SỬ XEM ĐÁM MÂY ====================

  Future<List<HongguoCloudProgress>> refreshHistory() async {
    final gen = state.value.generation;
    final creds = state.value.credentials;
    if (creds == null || !creds.isValid) return const <HongguoCloudProgress>[];

    final listRaw = await _signedRequest(
      creds,
      '/reading/bookapi/read_progress/list/v1/',
      query: const <String, String>{
        'book_types': '2',
        'limit': '50',
      },
    );
    final rowsRaw =
        listRaw['video_data'] ?? (listRaw['data'] is Map ? listRaw['data']['video_data'] : null);
    var parsed = parseProgressRows(rowsRaw);

    if (parsed.isNotEmpty) {
      final missingIds = parsed
          .where((e) => e.title.isEmpty && _numericIdRegex.hasMatch(e.seriesId))
          .map((e) => e.seriesId)
          .toSet()
          .toList(growable: false);
      if (missingIds.isNotEmpty) {
        final details = await _fetchMultiDetails(creds, missingIds);
        parsed = parsed.map((p) {
          final meta = details[p.seriesId];
          if (meta == null) return p;
          return p.copyWith(
            title: meta.title.isNotEmpty ? meta.title : null,
            cover: meta.cover.isNotEmpty ? meta.cover : null,
            totalEpisodes: meta.episodeCount > 0 ? meta.episodeCount : null,
            badge: meta.episodeCount > 0 ? 'Trọn bộ ${meta.episodeCount} tập' : null,
          );
        }).toList(growable: false);
      }
    }

    if (gen == state.value.generation) {
      state.value = state.value.copyWith(history: parsed);
    }
    return parsed;
  }

  /// Parse dữ liệu `video_data` từ API lịch sử đám mây (giữ chính xác `current_play_time` và chuẩn hoá timestamp sang ms).
  static List<HongguoCloudProgress> parseProgressRows(dynamic rows) {
    if (rows is! List) return const <HongguoCloudProgress>[];
    final out = <HongguoCloudProgress>[];
    for (final item in rows) {
      if (item is! Map) continue;
      final seriesId = (item['series_id'] ?? item['book_id'] ?? '').toString().trim();
      final vid = (item['vid'] ?? item['item_id'] ?? '').toString().trim();
      if (seriesId.isEmpty) continue;

      final vidIndex = (item['vid_index'] as num?)?.toInt() ?? 1;
      final epIndex = vidIndex > 0 ? vidIndex : 1;
      final posMs = (item['current_play_time'] as num?)?.toInt() ?? 0;
      final durMs = (item['current_total_time'] as num?)?.toInt() ?? 0;
      var updatedAt = (item['last_watch_time'] as num?)?.toInt() ??
          (item['read_timestamp_ms'] as num?)?.toInt() ??
          0;
      if (updatedAt > 0 && updatedAt < 100000000000) {
        updatedAt *= 1000;
      }

      out.add(
        HongguoCloudProgress(
          seriesId: seriesId,
          title: item['series_title']?.toString() ?? item['book_name']?.toString() ?? '',
          cover: item['thumb_url']?.toString() ?? item['cover']?.toString() ?? '',
          episodeId: vid,
          episodeIndex: epIndex,
          positionMs: posMs < 0 ? 0 : posMs,
          durationMs: durMs < 0 ? 0 : durMs,
          updatedAtMs: updatedAt,
        ),
      );
    }
    return out;
  }

  // ==================== YÊU THÍCH (TỦ PHIM) + XÁC NHẬN ĐỌC LẠI ====================

  Future<List<HongguoCloudFavorite>> refreshFavorites() async {
    final gen = state.value.generation;
    final creds = state.value.credentials;
    if (creds == null || !creds.isValid) return const <HongguoCloudFavorite>[];

    final raw = await _signedRequest(
      creds,
      '/reading/bookapi/bookshelf/video/info/v1/',
    );
    final data = raw['data'];
    if (data is! Map || !data.containsKey('video_shelf_info')) {
      throw const HongguoAuthException('Định dạng tủ phim yêu thích đã thay đổi');
    }
    final rows = data['video_shelf_info'];
    final result = <HongguoCloudFavorite>[];
    if (rows is List) {
      for (final item in rows) {
        if (item is! Map) continue;
        final video = item['video_data'] is Map ? item['video_data'] as Map : item;
        final id = (video['series_id'] ?? item['series_id'] ?? item['book_id'] ?? '')
            .toString()
            .trim();
        if (id.isEmpty) continue;
        final title = (item['series_title'] ??
                video['series_title'] ??
                video['title'] ??
                item['book_name'] ??
                '')
            .toString();
        final cover = (item['series_cover_url'] ??
                video['cover'] ??
                video['cover_url'] ??
                video['series_cover'] ??
                video['thumb_url'] ??
                item['thumb_url'] ??
                '')
            .toString();
        final epCnt = _readEpisodeCount(video) > 0
            ? _readEpisodeCount(video)
            : _readEpisodeCount(item);
        result.add(
          HongguoCloudFavorite(
            seriesId: id,
            title: title,
            cover: cover,
            totalEpisodes: epCnt,
            badge: epCnt > 0 ? 'Trọn bộ $epCnt tập' : '',
          ),
        );
      }
    }
    if (gen == state.value.generation) {
      final serverIds = result.map((e) => e.seriesId).toSet();
      final nextPending = state.value.favoritePendingIds
          .where((id) => !serverIds.contains(id))
          .toSet();
      state.value = state.value.copyWith(
        favorites: result,
        favoritePendingIds: nextPending,
      );
    }
    return result;
  }

  /// Thêm hoặc xoá khỏi tủ phim cloud kèm read-back verification (idempotent & chống trùng ghi).
  Future<String> setFavorite({
    required String seriesId,
    String title = '',
    required bool add,
  }) async {
    final gen = state.value.generation;
    final creds = state.value.credentials;
    if (creds == null || !creds.isValid) {
      throw const HongguoAuthException('Cần đăng nhập tài khoản để đồng bộ yêu thích');
    }
    if (!_numericIdRegex.hasMatch(seriesId)) {
      throw ArgumentError('Mã phim không hợp lệ');
    }
    if (state.value.isFavoritePending(seriesId)) {
      return 'Đang chờ đồng bộ tủ phim...';
    }

    // Kiểm tra trước trạng thái trên server.
    final currentList = await refreshFavorites();
    if (gen != state.value.generation) return '';
    final alreadyOnShelf = currentList.any((f) => f.seriesId == seriesId);
    if (alreadyOnShelf == add) {
      return add ? 'Đã có trong yêu thích' : 'Đã bỏ yêu thích';
    }

    final entry = <String, dynamic>{
      'book_id': seriesId,
      'book_type': 2,
      'modify_time': DateTime.now().millisecondsSinceEpoch,
      'video_shelf_operate_type': add ? 0 : 1,
      if (!add) 'group_name': '',
    };
    final body = <String, dynamic>{
      'is_cancelled': false,
      'update_bookshelf_video_list': <Map<String, dynamic>>[entry],
      if (add)
        'shark_extra': const <String, String>{
          'enter_from': 'MainFragmentActivity',
          'previous_page': '',
          'page_list': 'MainFragmentActivity',
          'is_active_behavior': 'true',
          'inactive_type': '0',
        },
    };

    final pending = <String>{...state.value.favoritePendingIds, seriesId};
    state.value = state.value.copyWith(favoritePendingIds: pending);

    await _signedRequest(
      creds,
      '/reading/bookapi/bookshelf/video/update/v1/',
      jsonBody: body,
    );

    // Read-back verification theo quy trình AccountFavoriteActionsTest.
    final afterList = await refreshFavorites();
    if (gen != state.value.generation) return '';
    final confirmed = afterList.any((f) => f.seriesId == seriesId) == add;
    if (!confirmed) {
      return add ? 'Đã gửi yêu cầu yêu thích (đang đồng bộ)' : 'Đã gửi yêu cầu bỏ thích';
    }
    final clearedPending = <String>{...state.value.favoritePendingIds}
      ..remove(seriesId);
    state.value = state.value.copyWith(favoritePendingIds: clearedPending);
    return add ? 'Đã lưu vào yêu thích tài khoản' : 'Đã xoá khỏi yêu thích';
  }

  // ==================== ĐẶT TRƯỚC (RESERVATIONS) ====================

  Future<void> refreshReservations() async {
    final gen = state.value.generation;
    final creds = state.value.credentials;
    if (creds == null || !creds.isValid) return;

    await Future.wait<void>(<Future<void>>[
      _fetchReservationsCategory(creds, online: true, generation: gen),
      _fetchReservationsCategory(creds, online: false, generation: gen),
    ]);
  }

  Future<void> _fetchReservationsCategory(
    HongguoAccountCredentials creds, {
    required bool online,
    required int generation,
  }) async {
    try {
      final raw = await _signedRequest(
        creds,
        '/reading/user/subscribe/list/v0/',
        query: <String, String>{
          'offset': '0',
          'limit': '20',
          'is_online': online.toString(),
          'tab_type': '13',
          'subscribe_order_type': '0',
          'swipe_type': '0',
          'need_calendar_schema': 'false',
          'subscribe_offset': '0',
        },
      );
      final data = raw['data'];
      if (data is! Map || !data.containsKey('subscribe_items')) {
        throw const HongguoAuthException('Danh sách đặt trước có định dạng lạ');
      }
      final items = data['subscribe_items'];
      var parsed = <HongguoCloudReservation>[];
      if (items is List) {
        for (final row in items) {
          if (row is! Map) continue;
          final sub = row['subscribe_data'] ?? row['video_data'] ?? row;
          if (sub is! Map) continue;
          final sid = (sub['series_id'] ?? row['series_id'] ?? row['book_id'] ?? '')
              .toString()
              .trim();
          if (sid.isEmpty) continue;
          final title = (sub['title'] ?? sub['series_title'] ?? '').toString();
          final cover = (sub['cover'] ?? sub['thumb_url'] ?? '').toString();
          final epCnt = _readEpisodeCount(sub);
          parsed.add(
            HongguoCloudReservation(
              seriesId: sid,
              title: title,
              cover: cover,
              badge: epCnt > 0 ? 'Trọn bộ $epCnt tập' : '',
              isOnline: online,
              releaseTimeText: sub['release_time_str']?.toString() ?? '',
            ),
          );
        }
      }

      if (online && parsed.isNotEmpty) {
        final missing = parsed
            .where((r) => r.badge.isEmpty && _numericIdRegex.hasMatch(r.seriesId))
            .map((r) => r.seriesId)
            .toList(growable: false);
        if (missing.isNotEmpty) {
          try {
            final details = await _fetchMultiDetails(creds, missing);
            parsed = parsed.map((r) {
              final d = details[r.seriesId];
              if (d == null || d.episodeCount <= 0) return r;
              return HongguoCloudReservation(
                seriesId: r.seriesId,
                title: r.title.isNotEmpty ? r.title : d.title,
                cover: r.cover.isNotEmpty ? r.cover : d.cover,
                badge: 'Trọn bộ ${d.episodeCount} tập',
                isOnline: r.isOnline,
                releaseTimeText: r.releaseTimeText,
              );
            }).toList(growable: false);
          } catch (_) {}
        }
      }

      if (generation != state.value.generation) return;
      if (online) {
        state.value = state.value.copyWith(
          onlineReservations: parsed,
          clearOnlineError: true,
        );
      } else {
        state.value = state.value.copyWith(
          upcomingReservations: parsed,
          clearUpcomingError: true,
        );
      }
    } catch (e) {
      if (generation != state.value.generation) return;
      final msg = 'Đọc danh sách đặt trước thất bại (${_sanitizeError(e)})';
      if (online) {
        state.value = state.value.copyWith(onlineReservationsError: msg);
      } else {
        state.value = state.value.copyWith(upcomingReservationsError: msg);
      }
    }
  }

  Future<bool> reserveSeries(String seriesId) async {
    final creds = state.value.credentials;
    if (creds == null || !creds.isValid) return false;
    final idInt = int.tryParse(seriesId);
    if (idInt == null) return false;
    await _signedRequest(
      creds,
      '/reading/bookapi/search/uncover_subscribe/v1/',
      jsonBody: <String, dynamic>{
        'item_id': idInt,
        'item_type': 3,
        'op_type': 1,
        'subscribe_source': 0,
      },
      gzipBody: true,
    );
    await refreshReservations();
    return state.value.upcomingReservations.any((r) => r.seriesId == seriesId) ||
        state.value.onlineReservations.any((r) => r.seriesId == seriesId);
  }

  // ==================== ĐỒNG BỘ TIẾN ĐỘ XEM (DEBOUNCED UPLOAD) ====================

  /// Lên lịch đẩy tiến độ lên cloud (gom 15s để tránh gọi mạng liên tục khi đang phát).
  void scheduleProgressUpload(
    HongguoCloudProgress progress, {
    int episodeCount = 0,
  }) {
    if (!state.value.isLoggedIn) return;
    _pendingUpload = progress;
    _pendingUploadEpisodeCount = episodeCount;
    _debounceTimer ??= Timer(const Duration(seconds: 15), () {
      _debounceTimer = null;
      unawaited(flushPendingProgress());
    });
  }

  Future<void> flushPendingProgress() async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final pending = _pendingUpload;
    if (pending == null || !state.value.isLoggedIn) return;
    _pendingUpload = null;
    try {
      await uploadProgressNow(pending, episodeCount: _pendingUploadEpisodeCount);
    } catch (e) {
      debugPrint('[HongguoCloud] Upload tiến độ nền lỗi: ${_sanitizeError(e)}');
    }
  }

  /// Đẩy tiến độ xem lên cloud ngay lập tức (dùng khi tạm dừng, chuyển tập, thoát màn hình).
  Future<void> uploadProgressNow(
    HongguoCloudProgress progress, {
    int episodeCount = 0,
  }) async {
    final creds = state.value.credentials;
    if (creds == null || !creds.isValid) return;
    if (!_numericIdRegex.hasMatch(progress.seriesId) ||
        !_numericIdRegex.hasMatch(progress.episodeId)) {
      return;
    }

    final sig =
        '${progress.seriesId}:${progress.episodeId}:${progress.episodeIndex}:${progress.positionMs ~/ 2000}';
    if (_lastUploadedSignature == sig) return;

    final rate = progress.durationMs > 0
        ? (progress.positionMs / progress.durationMs).clamp(0.0, 1.0)
        : 0.0;

    final entry = <String, dynamic>{
      'book_id': progress.seriesId,
      'item_id': progress.episodeId,
      'vid_index': progress.episodeIndex > 0 ? progress.episodeIndex : 1,
      'current_play_time': progress.positionMs < 0 ? 0 : progress.positionMs,
      'current_total_time': progress.durationMs < 0 ? 0 : progress.durationMs,
      'episode_count': episodeCount,
      'read_timestamp_ms': progress.updatedAtMs,
      'book_type': 2,
      'progress_rate': rate.toString(),
      'player_cumulative_total_duration':
          progress.positionMs < 0 ? 0 : progress.positionMs,
    };

    await _signedRequest(
      creds,
      '/reading/bookapi/read_progress/upload/v1/',
      jsonBody: <String, dynamic>{
        'books': <Map<String, dynamic>>[entry],
        'write_mode': 1,
      },
    );
    _lastUploadedSignature = sig;
  }

  // ==================== NETWORK HELPERS ====================

  Future<Map<String, ({String title, String cover, int episodeCount})>>
      _fetchMultiDetails(
    HongguoAccountCredentials creds,
    List<String> seriesIds,
  ) async {
    if (seriesIds.isEmpty) return const <String, ({String title, String cover, int episodeCount})>{};
    final raw = await _signedRequest(
      creds,
      '/reading/bookapi/multi-detail/v1/',
      query: <String, String>{
        'book_id': seriesIds.join(','),
        'book_type': '2',
      },
    );
    final rows = raw['data'];
    final map = <String, ({String title, String cover, int episodeCount})>{};
    if (rows is List) {
      for (final row in rows) {
        if (row is! Map) continue;
        final id = (row['book_id'] ?? row['series_id'] ?? '').toString().trim();
        if (id.isEmpty) continue;
        map[id] = (
          title: (row['book_name'] ?? row['series_title'] ?? row['title'] ?? '')
              .toString(),
          cover: (row['thumb_url'] ?? row['series_cover'] ?? '').toString(),
          episodeCount: _readEpisodeCount(row),
        );
      }
    }
    return map;
  }

  Future<Map<String, dynamic>> _signedRequest(
    HongguoAccountCredentials creds,
    String path, {
    Map<String, String> query = const <String, String>{},
    Map<String, dynamic>? jsonBody,
    bool gzipBody = false,
  }) async {
    final device = await HongguoDeviceService.instance.getOrRegisterDevice();
    final effectiveDid = (creds.deviceId.isNotEmpty && creds.deviceId != '0')
        ? creds.deviceId
        : device.deviceId;
    final effectiveIid = (creds.installId.isNotEmpty && creds.installId != '0')
        ? creds.installId
        : device.installId;

    final isPost = jsonBody != null;
    final List<int>? wireBytes;
    if (isPost) {
      final rawBytes = utf8.encode(jsonEncode(jsonBody));
      wireBytes = gzipBody ? gzip.encode(rawBytes) : rawBytes;
    } else {
      wireBytes = null;
    }

    // Đồng bộ tham số thiết bị chuẩn (aid=8662, app_name=novelread, version...)
    // theo CloudAccount.kt; thiếu các tham số này server trả mã 100103.
    final versionCode = isPost ? '73932' : '72232';
    final versionName = isPost ? '7.3.9.32' : '7.2.2.32';
    final mergedQuery = <String, String>{
      ...HongguoV5Constants.v3DeviceDefaults,
      'version_code': versionCode,
      'manifest_version_code': versionCode,
      'update_version_code': versionCode,
      'pv_player': versionCode,
      'version_name': versionName,
      'device_id': effectiveDid,
      'iid': effectiveIid,
      ...query,
    };

    final baseUri = Uri.parse('$apiBase$path').replace(
      queryParameters: mergedQuery,
    );

    final signed = HongguoSixgodSigner.signRequest(
      url: baseUri.toString(),
      body: wireBytes,
      deviceId: effectiveDid,
      installId: effectiveIid,
      includeHelios: true,
      versionName: versionName,
      userAgentOverride:
          isPost ? HongguoV5Constants.videoUa : HongguoV5Constants.appUa,
    );

    final headers = <String, String>{
      ...signed.headers,
      'Cookie': creds.cookie,
      'Accept-Encoding': 'gzip',
    };

    final Response<String> res;
    if (wireBytes != null) {
      if (gzipBody) {
        headers['Content-Encoding'] = 'gzip';
      }
      res = await _dio.post<String>(
        signed.signedUrl,
        data: Stream<List<int>>.fromIterable(<List<int>>[wireBytes]),
        options: Options(
          headers: <String, dynamic>{
            ...headers,
            Headers.contentLengthHeader: wireBytes.length,
          },
          responseType: ResponseType.plain,
        ),
      );
    } else {
      res = await _dio.get<String>(
        signed.signedUrl,
        options: Options(headers: headers, responseType: ResponseType.plain),
      );
    }

    final text = res.data ?? '';
    final stage = switch (path) {
      '/reading/user/info/v1/' => 'Hồ sơ tài khoản',
      '/reading/bookapi/read_progress/list/v1/' => 'Lịch sử xem đám mây',
      '/reading/bookapi/multi-detail/v1/' => 'Chi tiết phim đám mây',
      _ => 'Tài khoản đám mây',
    };
    if (text.trim().isEmpty) {
      throw HongguoAuthException(
        '$stage trả về phản hồi rỗng (HTTP ${res.statusCode ?? 0}/0B)',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw HongguoAuthException('$stage trả dữ liệu không hợp lệ');
    }
    if (decoded is! Map) {
      throw HongguoAuthException('$stage sai cấu trúc dữ liệu');
    }
    final root = Map<String, dynamic>.from(decoded);
    final code = (root['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw HongguoAuthException('$stage bị từ chối (mã lỗi $code)', errorCode: code);
    }
    return root;
  }

  static int _readEpisodeCount(Map<dynamic, dynamic> row) {
    for (final key in const <String>[
      'episode_cnt',
      'episode_count',
      'drama_chapter_number',
    ]) {
      final v = (row[key] as num?)?.toInt() ?? 0;
      if (v > 0) return v;
    }
    return 0;
  }

  static String _sanitizeError(Object error) {
    final s = error.toString();
    if (s.contains('sessionid') || s.contains('https://')) {
      return 'Lỗi kết nối máy chủ tài khoản Hồng Quả';
    }
    return s;
  }
}
