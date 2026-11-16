import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Hằng số giao thức v04.10.03 (v5) và hồ sơ thiết bị chuẩn từ hongguoTV.
class HongguoV5Constants {
  HongguoV5Constants._();

  static final Uint8List magic = _hexToBytes(
    '2d4b4fca49750d433fb5ae2c226dcc56',
  );

  static const String license = '646637794';
  static const String legacyLicense = '1588093228';

  static final Uint8List signKey = _hexToBytes(
    'b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d',
  );

  /// S-box 1024 byte cho AES-V3 v5 (4 từ x 256 byte).
  static final Uint8List sbox = _hexToBytes(
    '53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e'
    '2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d'
    'f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea'
    '8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a'
    '80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0'
    'b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d'
    'd12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cd'
    'bc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912'
    '38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55b'
    'a67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65'
    'b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272c'
    'e860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe'
    '1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a889136'
    '2fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8'
    '94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd95'
    '1d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc'
    'd759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952be'
    'a2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d'
    'e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99ea'
    'a6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e'
    '47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187'
    '745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28'
    '8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571'
    'c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5'
    'd09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d'
    '58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9'
    '1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46d'
    'a6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f'
    'd830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e'
    '98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168'
    '1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b85'
    '0b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e',
  );

  /// Bảng 64 hằng số HashTable 32-bit (dùng cho SHA-like hashF13 v5 & v3).
  static const List<int> hashTable = <int>[
    0xebb64faf, 0x07aadcc2, 0xcf3187bf, 0xe01138ff,
    0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8,
    0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51,
    0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288,
    0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00,
    0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e,
    0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83,
    0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c,
    0x617ce2a6, 0xe423417e, 0x0a40e143, 0x544e4032,
    0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x05b23bb3,
    0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50,
    0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8,
    0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581,
    0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14,
    0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1,
    0x6ca86f6e, 0x00284ba7, 0x08387cfa, 0x5fb37586,
  ];

  /// Muối KDF dùng chung giữa `DeviceRegister.ttEncrypt` và giải mã URL ẩn.
  static final Uint8List ttEncryptKdfSalt = _hexToBytes(
    '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524'
    'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58',
  );

  static const String videoUa =
      'com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)';
  static const String appUa =
      'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)';
  static const String playerUa =
      'com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)';
  static const String playerUaV5 =
      'com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)';

  /// Tham số query chuẩn cho mobile v5 playback (`/novel/player/multi_video_model/player/v1`).
  static const Map<String, String> v5PlaybackQueryDefaults = <String, String>{
    'aid': '8662',
    'app_name': 'novelread',
    'version_code': '74332',
    'version_name': '7.4.3.32',
    'channel': 'vivo_8662_64',
    'device_platform': 'android',
    'device_type': 'PGT-AN10',
    'os_version': '12',
    'update_version_code': '74332',
  };

  /// Tham số thiết bị v3 chuẩn từ VendorConstants.kt.
  static const Map<String, String> v3DeviceDefaults = <String, String>{
    'ac': 'wifi',
    'channel': 'update_64',
    'aid': '8662',
    'app_name': 'novelread',
    'version_code': '71332',
    'version_name': '7.1.3.32',
    'device_platform': 'android',
    'os': 'android',
    'ssmix': 'a',
    'device_type': '25053RT47C',
    'device_brand': 'Redmi',
    'language': 'zh',
    'os_api': '36',
    'os_version': '16',
    'manifest_version_code': '71332',
    'resolution': '1280*2772',
    'dpi': '520',
    'update_version_code': '71332',
    'host_abi': 'arm64-v8a',
    'dragon_device_type': 'phone',
    'pv_player': '71332',
    'compliance_status': '0',
    'need_personal_recommend': '1',
    'player_so_load': '1',
    'is_android_pad_screen': '0',
  };

  /// Sinh ngẫu nhiên nonce 18 byte dạng base64url không padding cho cold-start process.
  static String randomProcessNonce([List<int>? seedBytes]) {
    if (seedBytes != null) {
      return base64UrlEncode(seedBytes).replaceAll('=', '');
    }
    final rng = Random.secure();
    final bytes = Uint8List.fromList(
      List<int>.generate(18, (_) => rng.nextInt(256)),
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static Uint8List _hexToBytes(String hex) {
    final clean = hex.replaceAll(RegExp(r'\s+'), '');
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
