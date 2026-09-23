import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/repository/settings_repository.dart';
import '../../domain/font/custom_font_manager.dart';
import '../theme/app_theme.dart';
import 'gemini_key_test_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsRepository? _settings;
  final _apiKeysController = TextEditingController();
  final _customPromptController = TextEditingController();
  final _bilibiliSessDataController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await SettingsRepository.getInstance();
    setState(() {
      _settings = s;
      _apiKeysController.text = s.geminiApiKeys.join('\n');
      _customPromptController.text = s.geminiCustomPrompt;
      _bilibiliSessDataController.text = s.bilibiliSessData;
    });
  }

  void _save() {
    if (_settings == null) return;
    _settings!.geminiApiKeys = _apiKeysController.text
        .split(RegExp(r'[,;\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    _settings!.geminiCustomPrompt = _customPromptController.text.trim();
    _settings!.bilibiliSessData = _bilibiliSessDataController.text.trim();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Đã lưu cài đặt thành công!'),
        backgroundColor: AppColors.primaryEmerald,
      ),
    );
  }

  Future<void> _clearTemporaryCache() async {
    try {
      final tempDir = await getTemporaryDirectory();
      int freedBytes = 0;
      if (await tempDir.exists()) {
        final list = tempDir.listSync(recursive: true);
        for (final file in list) {
          if (file is File) {
            try {
              freedBytes += await file.length();
              await file.delete();
            } catch (_) {}
          }
        }
      }
      final freedMb = (freedBytes / (1024 * 1024)).toStringAsFixed(1);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã dọn dẹp bộ nhớ tạm: giải phóng $freedMb MB!'),
            backgroundColor: AppColors.primaryEmerald,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi dọn dẹp bộ nhớ tạm: $e')),
        );
      }
    }
  }

  void _openKeyTestDialog() {
    final keys = _apiKeysController.text
        .split(RegExp(r'[,;\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (keys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập ít nhất 1 Gemini API Key để kiểm tra!'),
        ),
      );
      return;
    }

    final currentModel = (_settings?.selectedModel.startsWith('gemini') == true)
        ? _settings!.selectedModel
        : 'gemini-3.5-flash-lite';

    showDialog(
      context: context,
      builder: (_) => GeminiKeyTestDialog(
        apiKeys: keys,
        initialModelId: currentModel,
        onRemoveDeadKeys: (aliveKeys) {
          setState(() {
            _apiKeysController.text = aliveKeys.join('\n');
            if (_settings != null) {
              _settings!.geminiApiKeys = aliveKeys;
            }
          });
        },
      ),
    );
  }

  @override
  void dispose() {
    _apiKeysController.dispose();
    _customPromptController.dispose();
    _bilibiliSessDataController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        backgroundColor: AppColors.darkBackground,
        title: const Text(
          'Cài đặt hệ thống',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.check, color: AppColors.primaryEmerald),
            onPressed: _save,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Section 1: Gemini AI
          _buildSectionHeader('Google Gemini AI (Dịch thuật đa luồng)'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Danh sách Gemini API Key (mỗi dòng 1 key để xoay vòng):',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _apiKeysController,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF1E202A),
                    hintText: 'Dán các API Key tại đây...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _apiKeysController,
                      builder: (context, val, _) {
                        final count = val.text
                            .split(RegExp(r'[,;\n]'))
                            .map((e) => e.trim())
                            .where((e) => e.isNotEmpty)
                            .length;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E202A),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.cardBorder),
                          ),
                          child: Text(
                            '$count key',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primaryEmerald,
                          side: const BorderSide(
                            color: AppColors.primaryEmerald,
                          ),
                          padding: const EdgeInsets.symmetric(
                            vertical: 10,
                            horizontal: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        icon: const Icon(Icons.bolt_rounded, size: 18),
                        label: const Text(
                          'Kiểm tra Key (Sống / Chết)',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onPressed: _openKeyTestDialog,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'SỐ LUỒNG DỊCH SONG SONG (GEMINI):',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${_settings!.geminiThreadCount} LUỒNG',
                      style: const TextStyle(
                        color: AppColors.primaryEmerald,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _settings!.geminiThreadCount.toDouble(),
                  min: 1,
                  max: 8,
                  divisions: 7,
                  activeColor: AppColors.primaryEmerald,
                  onChanged: (val) {
                    setState(() {
                      _settings!.geminiThreadCount = val.toInt();
                    });
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  'SỐ CÂU PHỤ ĐỀ / REQUEST (BATCH SIZE):',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Số câu phụ đề gửi lên Gemini trong mỗi lượt dịch. Số câu nhiều hơn giúp tăng tốc độ dịch và tiết kiệm lượt gọi API.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E202A),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: [30, 45, 60, 80, 100].contains(_settings!.geminiBatchSize)
                          ? _settings!.geminiBatchSize
                          : 45,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1E202A),
                      icon: const Icon(
                        Icons.keyboard_arrow_down,
                        color: AppColors.primaryEmerald,
                      ),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      items: const [
                        DropdownMenuItem<int>(
                          value: 30,
                          child: Text(
                            '30 câu / request (Chia nhỏ, dịch rất kỹ)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem<int>(
                          value: 45,
                          child: Text(
                            '45 câu / request (Mặc định - Khuyên dùng)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem<int>(
                          value: 60,
                          child: Text(
                            '60 câu / request (Nhanh hơn, tiết kiệm request)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem<int>(
                          value: 80,
                          child: Text(
                            '80 câu / request (Tối ưu cho video dài)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        DropdownMenuItem<int>(
                          value: 100,
                          child: Text(
                            '100 câu / request (Cực nhanh, ít gọi API)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            _settings!.geminiBatchSize = val;
                          });
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(color: AppColors.cardBorder),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'SỐ LUỒNG NHẬN DIỆN CAPCUT (STT):',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${_settings!.capcutSttConcurrency} LUỒNG',
                      style: const TextStyle(
                        color: AppColors.primaryEmerald,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Xử lý song song nhiều phân đoạn âm thanh qua CapCut Cloud, giúp tạo sub cho video dài (1-3 tiếng) nhanh gấp 2-3 lần (Khuyên dùng: 2 - 4 luồng).',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Slider(
                  value: _settings!.capcutSttConcurrency.toDouble(),
                  min: 1,
                  max: 6,
                  divisions: 5,
                  activeColor: AppColors.primaryEmerald,
                  onChanged: (val) {
                    setState(() {
                      _settings!.capcutSttConcurrency = val.toInt();
                    });
                  },
                ),
                const SizedBox(height: 12),
                const Divider(color: AppColors.cardBorder),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'SỐ LUỒNG CẮT ÂM THANH ĐỒNG THỜI:',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${_settings!.audioSliceConcurrency} LUỒNG',
                      style: const TextStyle(
                        color: AppColors.primaryEmerald,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Số luồng trích xuất các phân đoạn âm thanh song song từ file âm thanh tổng (Khuyên dùng: 2 - 4 luồng).',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Slider(
                  value: _settings!.audioSliceConcurrency.toDouble(),
                  min: 1,
                  max: 6,
                  divisions: 5,
                  activeColor: AppColors.primaryEmerald,
                  onChanged: (val) {
                    setState(() {
                      _settings!.audioSliceConcurrency = val.toInt();
                    });
                  },
                ),
                const SizedBox(height: 12),
                const Divider(color: AppColors.cardBorder),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        'THỜI LƯỢNG MỖI PHÂN ĐOẠN (GỬI CAPCUT):',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E202A),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.remove_circle_outline_rounded,
                              size: 20,
                              color: AppColors.primaryEmerald,
                            ),
                            tooltip: 'Giảm 1 phút',
                            onPressed: _settings!.audioChunkDurationMin > 1
                                ? () {
                                    setState(() {
                                      _settings!.audioChunkDurationMin--;
                                    });
                                  }
                                : null,
                          ),
                          Container(
                            constraints: const BoxConstraints(minWidth: 64),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              '${_settings!.audioChunkDurationMin} PHÚT',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(
                              Icons.add_circle_outline_rounded,
                              size: 20,
                              color: AppColors.primaryEmerald,
                            ),
                            tooltip: 'Tăng 1 phút',
                            onPressed: _settings!.audioChunkDurationMin < 15
                                ? () {
                                    setState(() {
                                      _settings!.audioChunkDurationMin++;
                                    });
                                  }
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Thời lượng tối đa của mỗi đoạn âm thanh khi gửi nhận diện CapCut Cloud (từ 1 đến 15 phút, mặc định: 10 phút). Video ngắn hơn mốc này sẽ gửi nguyên file.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Slider(
                  value: _settings!.audioChunkDurationMin.toDouble(),
                  min: 1,
                  max: 15,
                  divisions: 14,
                  activeColor: AppColors.primaryEmerald,
                  onChanged: (val) {
                    setState(() {
                      _settings!.audioChunkDurationMin = val.toInt();
                    });
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 3: Phông chữ phụ đề (Custom Font)
          _buildSectionHeader('PHÔNG CHỮ PHỤ ĐỀ (CUSTOM FONT)'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Khung xem trước font
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF14151C),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'XEM TRƯỚC PHÔNG CHỮ:',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            _settings!.selectedFontFamily.isEmpty
                                ? 'Mặc định hệ thống'
                                : _settings!.selectedFontFamily,
                            style: const TextStyle(
                              color: AppColors.primaryEmerald,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Xin chào thế giới! Phụ đề tiếng Việt 123',
                        style: TextStyle(
                          fontFamily: _settings!.selectedFontFamily.isEmpty
                              ? null
                              : _settings!.selectedFontFamily,
                          color: Colors.white,
                          fontSize: _settings!.subtitleFontSize.clamp(12.0, 22.0),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Nút nhập font
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primaryEmerald,
                      side: const BorderSide(color: AppColors.primaryEmerald),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.file_upload_outlined, size: 20),
                    label: const Text(
                      'Nhập Phông Chữ Từ File (.ttf, .otf)',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    onPressed: () async {
                      try {
                        final family =
                            await CustomFontManager.pickAndImportFont(
                          _settings!,
                        );
                        if (family != null) {
                          setState(() {});
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Đã nạp thành công phông chữ "$family"!',
                                ),
                                backgroundColor: AppColors.primaryEmerald,
                              ),
                            );
                          }
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Lỗi nhập phông chữ: $e'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      }
                    },
                  ),
                ),
                const SizedBox(height: 14),

                // Danh sách font
                const Text(
                  'DANH SÁCH PHÔNG CHỮ:',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),

                // Font mặc định
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    _settings!.selectedFontFamily.isEmpty
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: _settings!.selectedFontFamily.isEmpty
                        ? AppColors.primaryEmerald
                        : Colors.white38,
                    size: 20,
                  ),
                  title: const Text(
                    'Mặc định hệ thống',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  onTap: () {
                    setState(() {
                      _settings!.selectedFontFamily = '';
                    });
                  },
                ),

                // Các font tùy chỉnh đã nhập
                ..._settings!.customFonts.map((family) {
                  final isSelected = _settings!.selectedFontFamily == family;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      isSelected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: isSelected
                          ? AppColors.primaryEmerald
                          : Colors.white38,
                      size: 20,
                    ),
                    title: Text(
                      family,
                      style: TextStyle(
                        fontFamily: family,
                        color: isSelected ? AppColors.primaryEmerald : Colors.white,
                        fontSize: 14,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: Colors.redAccent, size: 20),
                      tooltip: 'Xóa phông chữ này',
                      onPressed: () async {
                        await CustomFontManager.deleteFont(family, _settings!);
                        setState(() {});
                      },
                    ),
                    onTap: () {
                      setState(() {
                        _settings!.selectedFontFamily = family;
                      });
                    },
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section 3: Tải video & Bilibili VIP
          _buildSectionHeader('TẢI VIDEO ONLINE & BILIBILI VIP'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'SỐ LUỒNG TẢI VIDEO & AUDIO SONG SONG:',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    Text(
                      '${_settings!.downloadThreadCount} LUỒNG',
                      style: const TextStyle(
                        color: AppColors.primaryEmerald,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Tải đa luồng song song luân phiên qua các cụm máy chủ CDN (Tencent, Alibaba, Huawei, Bilibili) giúp tăng tốc độ tải video và âm thanh lên gấp 5-10 lần (Khuyên dùng: 12 - 24 luồng).',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Slider(
                  value: _settings!.downloadThreadCount.toDouble(),
                  min: 8.0,
                  max: 32.0,
                  divisions: 24,
                  activeColor: AppColors.primaryEmerald,
                  inactiveColor: const Color(0xFF323444),
                  onChanged: (val) {
                    setState(() {
                      _settings!.downloadThreadCount = val.toInt();
                    });
                  },
                ),
                const Divider(color: AppColors.cardBorder),
                const SizedBox(height: 4),
                const Text(
                  'BILIBILI COOKIE (SESSDATA):',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Nhập mã SESSDATA tài khoản Bilibili để mở khóa xem và tải chất lượng cao 1080P+, 4K và các video giới hạn VIP.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _bilibiliSessDataController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF1E202A),
                    hintText: 'Nhập mã SESSDATA...',
                    hintStyle: const TextStyle(color: Colors.white38),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Section 5: Quản lý bộ nhớ
          const SizedBox(height: 16),
          _buildSectionHeader('Quản lý bộ nhớ & Dọn dẹp cache'),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bộ nhớ đệm video tạm (tmp):',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Trên iOS, khi chọn video từ máy hệ điều hành sẽ tạo bản sao tạm trong thư mục tmp. Bạn có thể dọn dẹp để giải phóng dung lượng máy bất cứ lúc nào.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.orangeAccent,
                    side: const BorderSide(color: Colors.orangeAccent),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                  label: const Text('Dọn dẹp bộ nhớ đệm video tạm'),
                  onPressed: _clearTemporaryCache,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryEmerald,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.save),
            onPressed: _save,
            label: const Text(
              'Lưu Cài Đặt',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          color: AppColors.primaryEmerald,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    );
  }
}
