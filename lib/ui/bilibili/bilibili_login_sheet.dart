import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/media/bilibili_resolver.dart';
import '../theme/app_theme.dart';

class BilibiliLoginSheet extends StatefulWidget {
  final VoidCallback? onLoginSuccess;

  const BilibiliLoginSheet({super.key, this.onLoginSuccess});

  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => const BilibiliLoginSheet(),
    );
  }

  @override
  State<BilibiliLoginSheet> createState() => _BilibiliLoginSheetState();
}

class _BilibiliLoginSheetState extends State<BilibiliLoginSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final BilibiliResolver _resolver = BilibiliResolver();

  // QR Code State
  BilibiliQrCodeInfo? _qrInfo;
  bool _isLoadingQr = true;
  String _qrStatusMessage = 'Đang tải mã QR...';
  bool _isQrExpired = false;
  Timer? _qrPollTimer;

  // WebView State
  WebViewController? _webViewController;
  bool _isLoadingWeb = true;

  // Manual Input State
  final TextEditingController _sessDataController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _initQrLogin();
  }

  void _onTabChanged() {
    if (_tabController.index == 1 && _webViewController == null) {
      _initWebView();
    }
  }

  // =================== QR LOGIN ===================
  Future<void> _initQrLogin() async {
    _qrPollTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _isLoadingQr = true;
      _isQrExpired = false;
      _qrStatusMessage = 'Đang tạo mã QR đăng nhập...';
    });

    try {
      final info = await _resolver.generateLoginQrCode();
      if (!mounted) return;
      setState(() {
        _qrInfo = info;
        _isLoadingQr = false;
        _qrStatusMessage = 'Vui lòng mở ứng dụng Bilibili để quét mã';
      });
      _startQrPolling(info.qrcodeKey);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingQr = false;
        _qrStatusMessage = 'Không thể tạo mã QR: $e';
      });
    }
  }

  void _startQrPolling(String qrcodeKey) {
    _qrPollTimer?.cancel();
    _qrPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      try {
        final result = await _resolver.pollLoginQrCode(qrcodeKey);
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (result.isSuccess) {
          timer.cancel();
          final sessData = result.sessData!;
          await _saveAndCompleteLogin(sessData, result.biliJct);
        } else if (result.code == 86090) {
          setState(() {
            _qrStatusMessage = '📱 Đã quét! Vui lòng bấm Xác nhận trên điện thoại...';
          });
        } else if (result.isExpired) {
          timer.cancel();
          setState(() {
            _isQrExpired = true;
            _qrStatusMessage = 'Mã QR đã hết hạn. Bấm để làm mới.';
          });
        }
      } catch (_) {}
    });
  }

  // =================== WEBVIEW LOGIN ===================
  void _initWebView() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36',
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            _checkUrlForSessData(url);
          },
          onPageFinished: (url) async {
            if (mounted) {
              setState(() => _isLoadingWeb = false);
            }
            _checkUrlForSessData(url);
            _checkCookieFromJs();
          },
          onNavigationRequest: (request) {
            _checkUrlForSessData(request.url);
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse('https://passport.bilibili.com/login'));

    setState(() {
      _webViewController = controller;
    });
  }

  void _checkUrlForSessData(String url) {
    try {
      final uri = Uri.tryParse(url);
      if (uri != null) {
        final sessData = uri.queryParameters['SESSDATA'];
        if (sessData != null && sessData.isNotEmpty) {
          _saveAndCompleteLogin(sessData);
        }
      }
    } catch (_) {}
  }

  Future<void> _checkCookieFromJs() async {
    if (_webViewController == null) return;
    try {
      final cookies = await _webViewController!.runJavaScriptReturningResult(
        'document.cookie',
      );
      final cookieStr = cookies.toString();
      final match = RegExp(r'SESSDATA=([^;]+)').firstMatch(cookieStr);
      final jctMatch = RegExp(r'bili_jct=([^;]+)').firstMatch(cookieStr);
      final biliJct = jctMatch?.group(1)?.replaceAll('"', '') ?? '';
      if (match != null) {
        final sessData = match.group(1)?.replaceAll('"', '') ?? '';
        if (sessData.isNotEmpty) {
          await _saveAndCompleteLogin(sessData, biliJct);
        }
      }
    } catch (_) {}
  }

  // =================== SAVE & FINISH ===================
  Future<void> _saveAndCompleteLogin(String sessData, [String? biliJct]) async {
    _qrPollTimer?.cancel();
    final cleanSess = sessData.trim();
    final settings = await SettingsRepository.getInstance();
    settings.bilibiliSessData = cleanSess;
    if (biliJct != null && biliJct.trim().isNotEmpty) {
      settings.bilibiliBiliJct = biliJct.trim();
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🎉 Đăng nhập Bilibili thành công! Đã lưu phiên làm việc.'),
        backgroundColor: Color(0xFF00AEEC),
        behavior: SnackBarBehavior.floating,
      ),
    );
    widget.onLoginSuccess?.call();
    Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    _qrPollTimer?.cancel();
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _sessDataController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: AppTheme.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00AEEC).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.tv_rounded,
                    color: Color(0xFF00AEEC),
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Đăng nhập Bilibili',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Xem 1080p+, mở khóa video Hội Viên (VIP)',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white70),
                ),
              ],
            ),
          ),

          // Tabs
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.darkSurfaceVariant,
              borderRadius: BorderRadius.circular(12),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorSize: TabBarIndicatorSize.tab,
              indicator: BoxDecoration(
                color: const Color(0xFF00AEEC),
                borderRadius: BorderRadius.circular(12),
              ),
              labelColor: Colors.white,
              unselectedLabelColor: AppTheme.textSecondary,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              tabs: const [
                Tab(
                  icon: Icon(Icons.qr_code_scanner_rounded, size: 18),
                  text: 'Quét mã QR',
                ),
                Tab(
                  icon: Icon(Icons.web_rounded, size: 18),
                  text: 'Đăng nhập Web',
                ),
              ],
            ),
          ),

          // Tab views
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildQrTabView(),
                _buildWebTabView(),
              ],
            ),
          ),

          // Manual input fallback button
          Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, bottomInset + 16),
            child: TextButton.icon(
              onPressed: _showManualSessDataDialog,
              icon: const Icon(Icons.key_rounded, size: 16, color: Colors.white60),
              label: const Text(
                'Nhập SESSDATA thủ công (nếu đã có)',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrTabView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const SizedBox(height: 12),
          // QR container card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: _isLoadingQr
                ? const SizedBox(
                    width: 200,
                    height: 200,
                    child: Center(
                      child: CircularProgressIndicator(color: Color(0xFF00AEEC)),
                    ),
                  )
                : (_qrInfo != null && !_isQrExpired)
                    ? QrImageView(
                        data: _qrInfo!.url,
                        version: QrVersions.auto,
                        size: 200,
                        backgroundColor: Colors.white,
                      )
                    : SizedBox(
                        width: 200,
                        height: 200,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.refresh_rounded,
                              size: 48,
                              color: Colors.black54,
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: _initQrLogin,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00AEEC),
                                foregroundColor: Colors.white,
                              ),
                              child: const Text('Tạo lại mã'),
                            ),
                          ],
                        ),
                      ),
          ),

          const SizedBox(height: 20),

          // Status message
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.darkSurfaceVariant,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_isQrExpired && !_isLoadingQr)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF00AEEC),
                    ),
                  ),
                if (!_isQrExpired && !_isLoadingQr) const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    _qrStatusMessage,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Instruction steps
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.darkSurfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hướng dẫn quét mã:',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                SizedBox(height: 8),
                _InstructionStep(
                  number: '1',
                  text: 'Mở app Bilibili (hoặc Bstation) trên điện thoại',
                ),
                SizedBox(height: 6),
                _InstructionStep(
                  number: '2',
                  text: 'Bấm biểu tượng Quét mã [  -  ] ở góc trên thanh tìm kiếm',
                ),
                SizedBox(height: 6),
                _InstructionStep(
                  number: '3',
                  text: 'Hướng camera quét mã QR trên màn hình và bấm Xác nhận',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebTabView() {
    if (_webViewController == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00AEEC)),
      );
    }

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: WebViewWidget(controller: _webViewController!),
        ),
        if (_isLoadingWeb)
          Container(
            color: AppTheme.darkSurface,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00AEEC)),
                  SizedBox(height: 12),
                  Text(
                    'Đang tải trang đăng nhập Bilibili...',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _showManualSessDataDialog() {
    showDialog(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppTheme.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
        title: const Text(
          'Nhập Cookie SESSDATA',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Nếu bạn đã lấy được chuỗi SESSDATA từ trình duyệt, hãy dán trực tiếp vào đây:',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _sessDataController,
              maxLines: 3,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Dán SESSDATA...',
                hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
                filled: true,
                fillColor: AppTheme.darkSurfaceVariant,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Hủy', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () {
              final text = _sessDataController.text.trim();
              if (text.isNotEmpty) {
                Navigator.of(dialogCtx).pop();
                _saveAndCompleteLogin(text);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00AEEC),
              foregroundColor: Colors.white,
            ),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
  }
}

class _InstructionStep extends StatelessWidget {
  final String number;
  final String text;

  const _InstructionStep({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF00AEEC).withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: const TextStyle(
              color: Color(0xFF00AEEC),
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
