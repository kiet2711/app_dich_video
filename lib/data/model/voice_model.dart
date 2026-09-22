class VoiceItem {
  final String voiceType;
  final String displayName;
  final String resourceId;
  final String lang;
  final String description;

  const VoiceItem({
    required this.voiceType,
    required this.displayName,
    required this.resourceId,
    this.lang = 'vi-VN',
    this.description = '',
  });

  Map<String, dynamic> toJson() => {
    'voiceType': voiceType,
    'displayName': displayName,
    'resourceId': resourceId,
    'lang': lang,
    'description': description,
  };

  factory VoiceItem.fromJson(Map<String, dynamic> json) => VoiceItem(
    voiceType: json['voiceType'] as String,
    displayName: json['displayName'] as String,
    resourceId: json['resourceId'] as String,
    lang: json['lang'] as String? ?? 'vi-VN',
    description: json['description'] as String? ?? '',
  );
}

class VoicePresets {
  static const List<VoiceItem> vietnameseVoices = [
    VoiceItem(
      voiceType: 'ICL_uranus_vi_female_yuenan1',
      displayName: 'Chị Dịu Dàng',
      resourceId: '7675984617253375253',
      description: 'Dịu dàng, truyền cảm',
    ),
    VoiceItem(
      voiceType: 'ICL_uranus_vi_female_yuenan4',
      displayName: 'Nàng Điềm Tĩnh',
      resourceId: '7675974812837219592',
      description: 'Điềm đạm, rõ ràng',
    ),
    VoiceItem(
      voiceType: 'ICL_uranus_vi_female_yuenan3',
      displayName: 'Em Gái Ngọt Ngào',
      resourceId: '7675982579366956308',
      description: 'Ngọt ngào, đáng yêu',
    ),
    VoiceItem(
      voiceType: 'multi_female_partner_uranus_bigtts',
      displayName: 'Quản Lý Vững Vàng',
      resourceId: '7654501692376993040',
      description: 'Chuyên nghiệp, quyền lực',
    ),
    VoiceItem(
      voiceType: 'ICL_uranus_vi_male_xinluyin',
      displayName: 'Người Kể Điềm Tĩnh',
      resourceId: '7668606732947574036',
      description: 'Trầm ấm, sâu lắng',
    ),
    VoiceItem(
      voiceType: 'ICL_uranus_vi_female_qcns',
      displayName: 'Nàng Tươi Tắn',
      resourceId: '7673047160434330900',
      description: 'Vui tươi, trẻ trung',
    ),
    VoiceItem(
      voiceType: 'ICL_uranus_vi_female_housangnvsheng',
      displayName: 'Thiếu Nữ Dịu Dàng',
      resourceId: '7659674297782258965',
      description: 'Nhẹ nhàng, tình cảm',
    ),
    VoiceItem(
      voiceType: 'ICL_uranus_vi_female_xfns',
      displayName: 'Cô Gái Năng Động',
      resourceId: '7673039258290081045',
      description: 'Năng động, cuốn hút',
    ),
    VoiceItem(
      voiceType: 'ICL_uranus_vi_male_cfzc',
      displayName: 'Chàng Trai Ấm Áp',
      resourceId: '7673075012848405761',
      description: 'Ấm áp, thân thiện',
    ),
    VoiceItem(
      voiceType: 'multi_male_felipe_uranus_bigtts',
      displayName: 'Giọng Nam Trầm',
      resourceId: '7637456729696996628',
      description: 'Nam tính, điện ảnh',
    ),
    VoiceItem(
      voiceType: 'multi_female_richgirl_uranus_bigtts',
      displayName: 'Review Phim New',
      resourceId: '7637460351541447956',
      description: 'Chuyên tóm tắt review phim',
    ),
    VoiceItem(
      voiceType: 'multi_female_stokie_uranus_bigtts',
      displayName: 'Review Phim 4',
      resourceId: '7637456729696996628',
      description: 'Kịch tính, nhanh gọn',
    ),
    VoiceItem(
      voiceType: 'multi_female_daqi_uranus_bigtts',
      displayName: 'Review Phim 3',
      resourceId: '7637451983389019409',
      description: 'Cuốn hút, hồi hộp',
    ),
    VoiceItem(
      voiceType: 'multi_female_xyf04auto_uranus_bigtts',
      displayName: 'Review Phim 2',
      resourceId: '7637458743197732117',
      description: 'Truyền cảm, nhấn nhá',
    ),
    VoiceItem(
      voiceType: 'multi_female_quanweinv_uranus_bigtts',
      displayName: 'Bản Tin 1',
      resourceId: '7637458743197732117',
      description: 'Thời sự, dứt khoát',
    ),
    VoiceItem(
      voiceType: 'multi_female_sisi_uranus_bigtts',
      displayName: 'Bản Tin Nữ',
      resourceId: '7637455857285860629',
      description: 'Phát thanh viên nữ',
    ),
    VoiceItem(
      voiceType: 'multi_female_xinwenjieshuo_uranus_bigtts',
      displayName: 'Nam Bản Tin',
      resourceId: '7637455039719640327',
      description: 'Phát thanh viên nam',
    ),
    VoiceItem(
      voiceType: 'multi_female_yangguangnv_uranus_bigtts',
      displayName: 'Ban Mai',
      resourceId: '7637456432522218773',
      description: 'Trong trẻo, tươi sáng',
    ),
    VoiceItem(
      voiceType: 'multi_female_peiqi_uranus_bigtts',
      displayName: 'Giọng Gái Mới Lớn',
      resourceId: '7637458789033151751',
      description: 'Hồn nhiên, tinh nghịch',
    ),
    VoiceItem(
      voiceType: 'BV075_streaming',
      displayName: 'Thanh Niên Tự Tin',
      resourceId: '7102355803792740865',
      description: 'Trẻ trung, hiện đại',
    ),
    VoiceItem(
      voiceType: 'BV074_streaming',
      displayName: 'Cô Gái Hoạt Ngôn',
      resourceId: '7102355709945188865',
      description: 'Nhanh nhẹn, lôi cuốn',
    ),
    VoiceItem(
      voiceType: 'vi_female_huong',
      displayName: 'Giọng Nữ Phổ Thông',
      resourceId: '7264854897953083905',
      description: 'Giọng chuẩn miền Bắc',
    ),
    VoiceItem(
      voiceType: 'BV421_vivn_streaming',
      displayName: 'Nhỏ Ngọt Ngào',
      resourceId: '7252594014782755330',
      description: 'Dễ thương',
    ),
    VoiceItem(
      voiceType: 'BV074_streaming_dsp',
      displayName: 'Giọng Bé',
      resourceId: '7550087831092251920',
      description: 'Trẻ em ngộ nghĩnh',
    ),
    VoiceItem(
      voiceType: 'BV562_streaming',
      displayName: 'Mai',
      resourceId: '7483736254694035984',
      description: 'Nhẹ nhàng',
    ),
    VoiceItem(
      voiceType: 'BV560_streaming',
      displayName: 'Alex Đại Đế',
      resourceId: '7483736167565758992',
      description: 'Uy nghiêm, mạnh mẽ',
    ),
  ];

  static final VoiceItem defaultVoice = vietnameseVoices[0];
}
