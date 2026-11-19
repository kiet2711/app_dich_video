import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/media/hongguo/hongguo_auth_service.dart';
import '../../domain/media/hongguo/hongguo_cloud_account_service.dart';
import '../theme/app_theme.dart';

/// Cửa sổ Quản lý & Đăng nhập Tài khoản Đám mây Hồng Quả (QR chính thức, SMS App Passport,
/// Lịch sử Cloud, Yêu thích 2 chiều & Đặt trước).
class HongguoAccountSheet extends StatefulWidget {
  final void Function(String seriesId, {int episodeIndex, int positionMs})?
      onOpenSeries;

  const HongguoAccountSheet({super.key, this.onOpenSeries});

  static Future<void> show(
    BuildContext context, {
    void Function(String seriesId, {int episodeIndex, int positionMs})?
        onOpenSeries,
  }) {
    final inheritedTheme = Theme.of(context);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Theme(
        data: inheritedTheme,
        child: HongguoAccountSheet(onOpenSeries: onOpenSeries),
      ),
    );
  }

  @override
  State<HongguoAccountSheet> createState() => _HongguoAccountSheetState();
}

class _HongguoAccountSheetState extends State<HongguoAccountSheet>
    with SingleTickerProviderStateMixin {
  late TabController _loginTabController;
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _codeCtrl = TextEditingController();

  HongguoCountryCode _selectedCountry = kHongguoCountryCodes.first;
  HongguoQrSession? _qrSession;
  HongguoQrPollStatus _qrStatus = HongguoQrPollStatus.pending;
  bool _qrLoading = false;
  String? _qrError;
  Timer? _qrPollTimer;

  bool _smsSending = false;
  bool _smsVerifying = false;
  bool _smsSent = false;
  int _smsCountdown = 0;
  Timer? _smsTimer;
  String? _smsMessage;
  bool _smsIsError = false;

  int _dashboardTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _loginTabController = TabController(length: 2, vsync: this);
    final cloud = HongguoCloudAccountService.instance;
    if (cloud.state.value.isLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(cloud.refreshAll());
        }
      });
    } else {
      unawaited(
        cloud.initialize().then((_) {
          if (mounted && !cloud.state.value.isLoggedIn) {
            _loadQr();
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    _qrPollTimer?.cancel();
    _smsTimer?.cancel();
    _loginTabController.dispose();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadQr() async {
    _qrPollTimer?.cancel();
    setState(() {
      _qrLoading = true;
      _qrError = null;
      _qrStatus = HongguoQrPollStatus.pending;
    });
    try {
      final session = await HongguoAuthService.instance.fetchQrCode();
      if (!mounted) return;
      setState(() {
        _qrSession = session;
        _qrLoading = false;
      });
      _startQrPolling(session.token);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _qrLoading = false;
        _qrError = e.toString();
      });
    }
  }

  void _startQrPolling(String token) {
    _qrPollTimer?.cancel();
    _qrPollTimer = Timer.periodic(const Duration(milliseconds: 2400), (_) async {
      if (!mounted) return;
      try {
        final res = await HongguoAuthService.instance.pollQrStatus(token);
        if (!mounted) return;
        setState(() => _qrStatus = res.status);
        if (res.status == HongguoQrPollStatus.confirmed &&
            res.credentials != null) {
          _qrPollTimer?.cancel();
          await HongguoCloudAccountService.instance
              .onLoginSucceeded(res.credentials!);
        }
      } catch (e) {
        if (!mounted) return;
        _qrPollTimer?.cancel();
        setState(() {
          _qrStatus = HongguoQrPollStatus.expired;
          _qrError = e.toString();
        });
      }
    });
  }

  Future<void> _sendSms() async {
    setState(() {
      _smsSending = true;
      _smsMessage = null;
      _smsIsError = false;
    });
    try {
      final res = await HongguoAuthService.instance.sendSmsCode(
        _selectedCountry.code,
        _phoneCtrl.text,
      );
      if (!mounted) return;
      setState(() {
        _smsSending = false;
        _smsSent = true;
        _smsMessage = 'Đã gửi mã xác nhận tới ${res.maskedMobile}';
        _smsIsError = false;
      });
      _startSmsCountdown(res.retrySeconds);
    } on HongguoCaptchaRequiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _smsSending = false;
        _smsMessage = e.message;
        _smsIsError = true;
      });
    } on HongguoAuthException catch (e) {
      if (!mounted) return;
      if (e.retrySeconds > 0) {
        _startSmsCountdown(e.retrySeconds);
      }
      setState(() {
        _smsSending = false;
        _smsMessage = e.message;
        _smsIsError = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _smsSending = false;
        _smsMessage = e.toString();
        _smsIsError = true;
      });
    }
  }

  void _startSmsCountdown(int seconds) {
    _smsTimer?.cancel();
    setState(() => _smsCountdown = seconds);
    _smsTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _smsCountdown <= 1) {
        t.cancel();
        if (mounted) setState(() => _smsCountdown = 0);
        return;
      }
      setState(() => _smsCountdown--);
    });
  }

  Future<void> _verifySms() async {
    setState(() {
      _smsVerifying = true;
      _smsMessage = null;
      _smsIsError = false;
    });
    try {
      final creds = await HongguoAuthService.instance.verifySmsCode(
        _codeCtrl.text,
      );
      if (!mounted) return;
      _smsTimer?.cancel();
      _qrPollTimer?.cancel();
      await HongguoCloudAccountService.instance.onLoginSucceeded(creds);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _smsVerifying = false;
        _smsMessage = e.toString();
        _smsIsError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppThemePalette.of(context);
    final accent = palette.accentFor(AppTabId.hongguo);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: ValueListenableBuilder<HongguoCloudAccountState>(
        valueListenable: HongguoCloudAccountService.instance.state,
        builder: (context, cloudState, _) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
                child: Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.account_circle_rounded,
                        color: accent,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            cloudState.isLoggedIn
                                ? 'Tài khoản Đám mây Hồng Quả'
                                : 'Đăng nhập Tài khoản Hồng Quả',
                            style: TextStyle(
                              color: palette.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            cloudState.isLoggedIn
                                ? (cloudState.profile?.userName ??
                                    'Đồng bộ lịch sử, yêu thích & đặt trước')
                                : 'Quét QR hoặc SMS để đồng bộ lịch sử & yêu thích',
                            style: TextStyle(
                              color: palette.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: palette.textMuted),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Divider(color: palette.border, height: 1),
              Flexible(
                child: cloudState.isLoggedIn
                    ? _buildLoggedInDashboard(palette, accent, cloudState)
                    : _buildLoginView(palette, accent),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLoginView(AppThemePalette palette, Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TabBar(
          controller: _loginTabController,
          indicatorColor: accent,
          labelColor: accent,
          unselectedLabelColor: palette.textMuted,
          dividerColor: palette.border,
          onTap: (idx) {
            if (idx == 0 && _qrSession == null && !_qrLoading) {
              _loadQr();
            }
          },
          tabs: const <Widget>[
            Tab(text: 'Quét Mã QR'),
            Tab(text: 'Số điện thoại (SMS)'),
          ],
        ),
        Flexible(
          child: SizedBox(
            height: 410,
            child: TabBarView(
              controller: _loginTabController,
              children: <Widget>[
                _buildQrTab(palette, accent),
                _buildSmsTab(palette, accent),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildQrTab(AppThemePalette palette, Color accent) {
    final statusText = switch (_qrStatus) {
      HongguoQrPollStatus.pending =>
        'Mở ứng dụng Hồng Quả trên điện thoại -> Quét mã QR bên trên',
      HongguoQrPollStatus.scanned =>
        'Đã quét mã! Vui lòng bấm Xác nhận trên điện thoại...',
      HongguoQrPollStatus.confirmed => 'Đăng nhập thành công! Đang đồng bộ...',
      HongguoQrPollStatus.expired => 'Mã QR đã hết hạn. Bấm làm mới để tạo lại.',
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: <Widget>[
          Container(
            width: 204,
            height: 204,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: palette.border),
              boxShadow: palette.cardShadows,
            ),
            child: _qrLoading
                ? Center(child: CircularProgressIndicator(color: accent))
                : (_qrSession != null
                    ? Image.memory(
                        _qrSession!.qrImageBytes,
                        fit: BoxFit.contain,
                      )
                    : Center(
                        child: Text(
                          _qrError ?? 'Chưa tải được mã QR',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 12,
                          ),
                        ),
                      )),
          ),
          const SizedBox(height: 14),
          Text(
            _qrError ?? statusText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _qrError != null
                  ? Colors.redAccent
                  : palette.textSecondary,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _qrLoading ? null : _loadQr,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Làm mới QR'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.textPrimary,
                  side: BorderSide(color: palette.border),
                ),
              ),
              if (_qrSession?.dragonDeeplink.isNotEmpty == true) ...<Widget>[
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: _qrSession!.dragonDeeplink),
                    );
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Đã sao chép liên kết mở App Hồng Quả'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.link, size: 18),
                  label: const Text('Link App'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    foregroundColor: palette.onColor(accent),
                    elevation: 0,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSmsTab(AppThemePalette palette, Color accent) {
    final successColor =
        palette.isDark ? Colors.greenAccent : const Color(0xFF15803D);
    final errorColor =
        palette.isDark ? const Color(0xFFFF8899) : Colors.redAccent;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DropdownButtonFormField<HongguoCountryCode>(
            initialValue: _selectedCountry,
            dropdownColor: palette.surface,
            style: TextStyle(color: palette.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Mã vùng quốc gia / khu vực',
              labelStyle: TextStyle(color: palette.textSecondary),
              filled: true,
              fillColor: palette.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.border),
              ),
            ),
            items: kHongguoCountryCodes
                .map(
                  (c) => DropdownMenuItem<HongguoCountryCode>(
                    value: c,
                    child: Text(c.name),
                  ),
                )
                .toList(growable: false),
            onChanged: (v) {
              if (v != null) setState(() => _selectedCountry = v);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _phoneCtrl,
            keyboardType: TextInputType.phone,
            style: TextStyle(color: palette.textPrimary),
            decoration: InputDecoration(
              labelText: 'Số điện thoại',
              hintText: _selectedCountry.code == '86'
                  ? '13800138000 (11 số)'
                  : 'Nhập số không cần mã vùng',
              hintStyle: TextStyle(color: palette.textMuted),
              labelStyle: TextStyle(color: palette.textSecondary),
              prefixText: '+${_selectedCountry.code} ',
              prefixStyle: TextStyle(color: accent, fontWeight: FontWeight.w600),
              filled: true,
              fillColor: palette.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: palette.border),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _codeCtrl,
                  keyboardType: TextInputType.number,
                  style: TextStyle(color: palette.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Mã OTP (4-6 số)',
                    labelStyle: TextStyle(color: palette.textSecondary),
                    filled: true,
                    fillColor: palette.surfaceAlt,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: palette.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: palette.border),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 52,
                child: OutlinedButton(
                  onPressed:
                      (_smsSending || _smsCountdown > 0) ? null : _sendSms,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.textPrimary,
                    side: BorderSide(color: palette.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _smsSending
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: accent,
                          ),
                        )
                      : Text(
                          _smsCountdown > 0
                              ? 'Gửi lại (${_smsCountdown}s)'
                              : 'Gửi OTP',
                        ),
                ),
              ),
            ],
          ),
          if (_smsMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (_smsIsError ? Colors.redAccent : successColor)
                    .withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _smsMessage!,
                style: TextStyle(
                  color: _smsIsError ? errorColor : successColor,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: (_smsVerifying || !_smsSent) ? null : _verifySms,
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: palette.onColor(accent),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _smsVerifying
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: palette.onColor(accent),
                      ),
                    )
                  : const Text(
                      'Đăng nhập bằng SMS',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoggedInDashboard(
    AppThemePalette palette,
    Color accent,
    HongguoCloudAccountState state,
  ) {
    final profile = state.profile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 22,
                backgroundColor: palette.surfaceAlt,
                backgroundImage:
                    (profile?.avatarUrl.isNotEmpty ?? false)
                        ? NetworkImage(profile!.avatarUrl)
                        : null,
                child: (profile?.avatarUrl.isEmpty ?? true)
                    ? Icon(Icons.person, color: palette.textMuted)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      profile?.userName ??
                          state.credentials?.userName ??
                          'Đã đăng nhập Hồng Quả',
                      style: TextStyle(
                        color: palette.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      profile != null
                          ? 'ID: ${profile.bizUserId}'
                          : (state.lastError ?? 'Đang đồng bộ hồ sơ...'),
                      style: TextStyle(
                        color: state.lastError != null
                            ? Colors.redAccent
                            : palette.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Đồng bộ lại',
                onPressed: state.isLoading
                    ? null
                    : () => HongguoCloudAccountService.instance.refreshAll(),
                icon: state.isLoading
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accent,
                        ),
                      )
                    : Icon(Icons.sync_rounded, color: palette.textSecondary),
              ),
              TextButton(
                onPressed: () => HongguoCloudAccountService.instance.logout(),
                child: const Text(
                  'Đăng xuất',
                  style: TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              ButtonSegment<int>(
                value: 0,
                label: Text('Lịch sử (${state.history.length})'),
              ),
              ButtonSegment<int>(
                value: 1,
                label: Text('Yêu thích (${state.favorites.length})'),
              ),
              ButtonSegment<int>(
                value: 2,
                label: Text(
                  'Đặt trước (${state.onlineReservations.length + state.upcomingReservations.length})',
                ),
              ),
            ],
            selected: <int>{_dashboardTabIndex},
            onSelectionChanged: (s) {
              setState(() => _dashboardTabIndex = s.first);
            },
          ),
        ),
        const SizedBox(height: 6),
        Flexible(
          child: SizedBox(
            height: 360,
            child: _buildDashboardList(palette, accent, state),
          ),
        ),
      ],
    );
  }

  Widget _buildDashboardList(
    AppThemePalette palette,
    Color accent,
    HongguoCloudAccountState state,
  ) {
    if (_dashboardTabIndex == 0) {
      if (state.history.isEmpty) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  state.historyError ?? 'Chưa có lịch sử xem trên đám mây',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: state.historyError != null
                        ? Colors.redAccent
                        : palette.textMuted,
                  ),
                ),
                if (state.historyError != null) ...<Widget>[
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: state.isLoading
                        ? null
                        : () => HongguoCloudAccountService.instance
                            .refreshHistory(),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('Thử lại'),
                  ),
                ],
              ],
            ),
          ),
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: state.history.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final item = state.history[index];
          final posSec = item.positionMs ~/ 1000;
          final durSec = item.durationMs ~/ 1000;
          return ListTile(
            tileColor: palette.surfaceAlt,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: palette.border),
            ),
            leading: _coverThumb(palette, item.cover),
            title: Text(
              item.title.isNotEmpty ? item.title : 'Phim #${item.seriesId}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Tập ${item.episodeIndex} • ${_formatSec(posSec)}${durSec > 0 ? ' / ${_formatSec(durSec)}' : ''}',
              style: TextStyle(color: palette.textSecondary, fontSize: 12),
            ),
            trailing: Icon(
              Icons.play_circle_outline_rounded,
              color: accent,
            ),
            onTap: () {
              Navigator.of(context).pop();
              widget.onOpenSeries?.call(
                item.seriesId,
                episodeIndex: item.episodeIndex,
                positionMs: item.positionMs,
              );
            },
          );
        },
      );
    }

    if (_dashboardTabIndex == 1) {
      if (state.favorites.isEmpty) {
        return Center(
          child: Text(
            'Tủ phim yêu thích đám mây đang trống',
            style: TextStyle(color: palette.textMuted),
          ),
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: state.favorites.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final fav = state.favorites[index];
          final pending = state.isFavoritePending(fav.seriesId);
          return ListTile(
            tileColor: palette.surfaceAlt,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: palette.border),
            ),
            leading: _coverThumb(palette, fav.cover),
            title: Text(
              fav.title.isNotEmpty ? fav.title : 'Phim #${fav.seriesId}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.textPrimary, fontSize: 14),
            ),
            subtitle: fav.badge.isNotEmpty
                ? Text(
                    fav.badge,
                    style: TextStyle(color: palette.textSecondary, fontSize: 12),
                  )
                : null,
            trailing: IconButton(
              icon: pending
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: accent),
                    )
                  : Icon(Icons.favorite, color: accent),
              onPressed: pending
                  ? null
                  : () => HongguoCloudAccountService.instance.setFavorite(
                        seriesId: fav.seriesId,
                        title: fav.title,
                        add: false,
                      ),
            ),
            onTap: () {
              Navigator.of(context).pop();
              widget.onOpenSeries?.call(fav.seriesId);
            },
          );
        },
      );
    }

    final allRes = <HongguoCloudReservation>[
      ...state.onlineReservations,
      ...state.upcomingReservations,
    ];
    if (allRes.isEmpty) {
      return Center(
        child: Text(
          state.onlineReservationsError ??
              state.upcomingReservationsError ??
              'Chưa có phim đặt trước',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.textMuted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: allRes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final r = allRes[index];
        return ListTile(
          tileColor: palette.surfaceAlt,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: palette.border),
          ),
          leading: _coverThumb(palette, r.cover),
          title: Text(
            r.title.isNotEmpty ? r.title : 'Phim #${r.seriesId}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: palette.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            r.isOnline
                ? 'Đã lên sóng ${r.badge}'
                : (r.releaseTimeText.isNotEmpty
                    ? 'Sắp chiếu: ${r.releaseTimeText}'
                    : 'Sắp ra mắt'),
            style: TextStyle(color: palette.textSecondary, fontSize: 12),
          ),
          onTap: r.isOnline
              ? () {
                  Navigator.of(context).pop();
                  widget.onOpenSeries?.call(r.seriesId);
                }
              : null,
        );
      },
    );
  }

  Widget _coverThumb(AppThemePalette palette, String url) {
    if (url.isEmpty) {
      return Container(
        width: 42,
        height: 56,
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(Icons.movie, color: palette.textMuted, size: 20),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url,
        width: 42,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: 42,
          height: 56,
          color: palette.surface,
          child: Icon(Icons.movie, color: palette.textMuted, size: 20),
        ),
      ),
    );
  }

  static String _formatSec(int totalSec) {
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
