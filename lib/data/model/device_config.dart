import 'dart:math';

class DeviceConfig {
  String aid;
  String appName;
  String appvr;
  String versionName;
  String versionCode;
  String channel;
  String devicePlatform;
  String deviceType;
  String deviceBrand;
  String osVersion;
  String deviceId;
  String iid;
  String region;
  String loc;
  String lan;
  String pf;
  String tdid;

  DeviceConfig({
    this.aid = '359289',
    this.appName = 'CapCut',
    this.appvr = '8.7.0',
    this.versionName = '8.7.0',
    this.versionCode = '8.7.0',
    this.channel = 'capcutpc_google',
    this.devicePlatform = 'mac',
    this.deviceType = 'MacBookPro17,4',
    this.deviceBrand = 'MacBookPro17,4',
    this.osVersion = '15.7.4',
    this.deviceId = '76471456455646328721',
    this.iid = '76471456455646328721',
    this.region = 'VN',
    this.loc = 'VN',
    this.lan = 'vi-VN',
    this.pf = '3',
    this.tdid = '76471456455646328721',
  });

  /// Tạo mới bộ ID ngẫu nhiên (20 chữ số) để làm mới danh tính thiết bị, tránh bị rate-limit.
  DeviceConfig randomize() {
    final random = Random();
    final firstDigits = 1000000000 + random.nextInt(899999999);
    final lastDigits = 1000000000 + random.nextInt(899999999);
    final newId = '$firstDigits${lastDigits}1';
    deviceId = newId;
    iid = newId;
    tdid = newId;
    return this;
  }

  Map<String, String> toQueryMap({bool includeRegion = true}) {
    final map = <String, String>{
      'app_name': appName,
      'device_type': deviceType,
      'os_version': osVersion,
      'channel': channel,
      'version_name': versionName,
      'device_brand': deviceBrand,
      'device_id': deviceId,
      'iid': iid,
      'version_code': versionCode,
      'device_platform': devicePlatform,
      'aid': aid,
    };
    if (includeRegion) {
      map['region'] = region;
    }
    return map;
  }
}
