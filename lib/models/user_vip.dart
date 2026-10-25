import '../config/app_config.dart';
import 'model_parsing.dart';

class LoginSession {
  const LoginSession({
    this.userId,
    this.token,
    this.t1,
    this.sessionId,
    this.nickname,
    this.avatarUrl,
  });

  final String? userId;
  final String? token;
  final String? t1;
  final String? sessionId;
  final String? nickname;
  final String? avatarUrl;

  bool get isValid =>
      (token != null && token!.isNotEmpty) ||
      (sessionId != null && sessionId!.isNotEmpty);

  factory LoginSession.fromJson(Map<String, dynamic> json) {
    return LoginSession(
      userId: asString(json['userid']),
      token: asString(json['token']),
      t1: asString(json['t1']),
    );
  }
}

class PhoneLoginResult {
  const PhoneLoginResult._({
    this.session,
    this.accounts = const [],
    this.message,
    this.errorCode,
  });

  const PhoneLoginResult.success(LoginSession session)
    : this._(session: session);

  const PhoneLoginResult.accountSelection({
    required List<MobileLoginAccount> accounts,
    String? message,
    int? errorCode,
  }) : this._(accounts: accounts, message: message, errorCode: errorCode);

  final LoginSession? session;
  final List<MobileLoginAccount> accounts;
  final String? message;
  final int? errorCode;

  bool get requiresUserSelection => accounts.isNotEmpty;
}

class MobileLoginAccount {
  const MobileLoginAccount({
    required this.userId,
    this.nickname,
    this.avatarUrl,
    this.appId,
    this.username,
  });

  final String userId;
  final String? nickname;
  final String? avatarUrl;
  final int? appId;
  final String? username;

  String get displayName => nickname?.trim().isNotEmpty == true
      ? nickname!.trim()
      : username?.trim().isNotEmpty == true
      ? username!.trim()
      : '账号 $userId';

  String? get subtitle {
    final values = [
      username?.trim(),
      if (appId != null) 'AppID $appId',
    ].whereType<String>().where((value) => value.isNotEmpty).toList();
    if (values.isEmpty) {
      return null;
    }
    return values.join(' · ');
  }

  factory MobileLoginAccount.fromJson(Map<String, dynamic> json) {
    return MobileLoginAccount(
      userId: asString(json['userId'] ?? json['userid']) ?? '',
      nickname: asString(json['nickname']),
      avatarUrl: normalizeImageUrl(asString(json['pic'] ?? json['avatar'])),
      appId: asInt(json['appId'] ?? json['appid']),
      username: asString(json['username']),
    );
  }
}

/// 本机已保存账号（多账号切换）。
///
/// 凭据仅存本机 SharedPreferences（[AuthController] 的账号列表），不上传。
/// [lastUsedAt]（毫秒）用于「最近使用」排序与登出/移除后的自动切换。
class SavedAccount {
  const SavedAccount({
    required this.userId,
    this.nickname,
    this.avatarUrl,
    this.token,
    this.t1,
    this.sessionId,
    required this.lastUsedAt,
  });

  /// 唯一键，永不为空（空 userId 的条目在解析时丢弃）。
  final String userId;
  final String? nickname;
  final String? avatarUrl;
  final String? token;
  final String? t1;
  final String? sessionId;
  final int lastUsedAt;

  String get displayName =>
      nickname?.trim().isNotEmpty == true ? nickname!.trim() : '账号 $userId';

  LoginSession toLoginSession() => LoginSession(
    userId: userId,
    token: token,
    t1: t1,
    sessionId: sessionId,
    nickname: nickname,
    avatarUrl: avatarUrl,
  );

  factory SavedAccount.fromLoginSession(LoginSession session, {int? lastUsedAt}) {
    final uid = session.userId?.trim() ?? '';
    return SavedAccount(
      userId: uid,
      nickname: session.nickname,
      avatarUrl: session.avatarUrl,
      token: session.token,
      t1: session.t1,
      sessionId: session.sessionId,
      lastUsedAt: lastUsedAt ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() => {
    'userId': userId,
    'nickname': nickname,
    'avatarUrl': avatarUrl,
    'token': token,
    't1': t1,
    'sessionId': sessionId,
    'lastUsedAt': lastUsedAt,
  };

  /// 容错解析：字段缺失/类型漂移按 null 处理；userId 为空视为无效条目
  /// （返回实例但 [isValid] 为 false，由调用方丢弃）。
  factory SavedAccount.fromJson(Map<String, dynamic> json) {
    return SavedAccount(
      userId: asString(json['userId']) ?? '',
      nickname: asString(json['nickname']),
      avatarUrl: asString(json['avatarUrl']),
      token: asString(json['token']),
      t1: asString(json['t1']),
      sessionId: asString(json['sessionId']),
      lastUsedAt: asInt(json['lastUsedAt']) ?? 0,
    );
  }

  bool get isValid => userId.isNotEmpty;
}

class UserProfile {
  const UserProfile({required this.nickname, this.avatarUrl});

  final String nickname;
  final String? avatarUrl;

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      nickname: asString(json['nickname']) ?? '${AppConfig.appName}用户',
      avatarUrl: normalizeImageUrl(asString(json['pic'])),
    );
  }

  Map<String, dynamic> toCache() => {
    'nickname': nickname,
    'avatarUrl': avatarUrl,
  };

  factory UserProfile.fromCache(Map<String, dynamic> json) {
    return UserProfile(
      nickname: asString(json['nickname']) ?? '${AppConfig.appName}用户',
      avatarUrl: asString(json['avatarUrl']),
    );
  }
}

class VipReceiveItem {
  const VipReceiveItem({this.day, this.receiveVip, this.vipType});

  final String? day;
  final int? receiveVip;
  final String? vipType;

  factory VipReceiveItem.fromJson(Map<String, dynamic> json) {
    return VipReceiveItem(
      day: asString(json['day']),
      receiveVip: asInt(json['receive_vip']),
      vipType: asString(json['vip_type']),
    );
  }
}

class VipReceiveHistory {
  const VipReceiveHistory({
    this.month,
    this.serverTime,
    this.items = const [],
    this.status,
    this.errorCode,
  });

  final String? month;
  final int? serverTime;
  final List<VipReceiveItem> items;
  final int? status;
  final int? errorCode;

  factory VipReceiveHistory.fromJson(Map<String, dynamic> json) {
    return VipReceiveHistory(
      month: asString(json['month']),
      serverTime: asInt(json['server_time']),
      items: asList(json['list'])
          .whereType<Map>()
          .map((item) => VipReceiveItem.fromJson(asMap(item)))
          .toList(),
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
    );
  }
}

class OneDayVipResult {
  const OneDayVipResult({this.status, this.errorCode});

  final int? status;
  final int? errorCode;

  factory OneDayVipResult.fromJson(Map<String, dynamic> json) {
    return OneDayVipResult(
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
    );
  }
}

class UpgradeVipResult {
  const UpgradeVipResult({this.status, this.errorCode});

  final int? status;
  final int? errorCode;

  factory UpgradeVipResult.fromJson(Map<String, dynamic> json) {
    return UpgradeVipResult(
      status: asInt(json['status']),
      errorCode: asInt(json['error_code']),
    );
  }
}

class BusiVipInfo {
  const BusiVipInfo({
    this.isVip,
    this.productType,
    this.busiType,
    this.vipBeginTime,
    this.vipEndTime,
    this.vipClearday,
  });

  final int? isVip;
  final String? productType;
  final String? busiType;
  final String? vipBeginTime;
  final String? vipEndTime;
  final String? vipClearday;

  bool get active => isVip == 1;

  String? get typeLabel => switch (productType) {
    'svip' => '概念版VIP',
    'tvip' => '畅听VIP',
    _ => null,
  };

  factory BusiVipInfo.fromJson(Map<String, dynamic> json) {
    return BusiVipInfo(
      isVip: asInt(json['is_vip']),
      productType: asString(json['product_type']),
      busiType: asString(json['busi_type']),
      vipBeginTime: asString(json['vip_begin_time']),
      vipEndTime: asString(json['vip_end_time']),
      vipClearday: asString(json['vip_clearday']),
    );
  }
}

class UserVipInfo {
  const UserVipInfo({
    this.isVip,
    this.vipType,
    this.busiVip = const [],
    this.isSuperVip,
    this.isConceptVip,
  });

  final int? isVip;
  final int? vipType;
  final List<BusiVipInfo> busiVip;
  final bool? isSuperVip;
  final bool? isConceptVip;

  bool get hasVip =>
      isVip == 1 ||
      (isSuperVip ?? false) ||
      (isConceptVip ?? false) ||
      activeVip != null;

  BusiVipInfo? get activeVip {
    for (final v in busiVip) {
      if (v.active) return v;
    }
    return null;
  }

  String? get expiryDisplay {
    final vip = activeVip;
    if (vip == null) return null;
    final end = vip.vipEndTime;
    if (end == null || end.isEmpty) return null;
    final label = vip.typeLabel ?? 'VIP';
    return '$label · $end 到期';
  }

  factory UserVipInfo.fromJson(Map<String, dynamic> json) {
    return UserVipInfo(
      isVip: asInt(json['is_vip']),
      vipType: asInt(json['vip_type']),
      busiVip: asList(
        json['busi_vip'],
      ).whereType<Map>().map((e) => BusiVipInfo.fromJson(asMap(e))).toList(),
      // 原始 API JSON 类型不稳定（可能下发 1/0），容错解析；缺失/为 null 时保持 null。
      isSuperVip: asBool(json['isSuperVip']),
      isConceptVip: asBool(json['isConceptVip']),
    );
  }
}

class QrCodeInfo {
  const QrCodeInfo({required this.key, required this.imageUrl});

  final String key;
  final String imageUrl;

  factory QrCodeInfo.fromJson(Map<String, dynamic> json) {
    return QrCodeInfo(
      key: asString(json['qrcode']) ?? '',
      imageUrl: asString(json['qrcode_img']) ?? '',
    );
  }
}

class QrCheckResult {
  const QrCheckResult({
    required this.status,
    this.token,
    this.userId,
    this.nickname,
    this.avatar,
  });

  final int status;
  final String? token;
  final String? userId;
  final String? nickname;
  final String? avatar;

  // 酷狗概念版二维码状态码（参考 jsososo/kugou-concept、ImUpXuu/KuGouWebPlayer）：
  //   0 = 已过期        1 = 等待扫码        2 = 已扫码待确认        4 = 登录成功
  bool get isWaitingForScan => status == 1;
  bool get isWaitingForConfirm => status == 2;
  bool get isExpired => status == 0;
  bool get isSuccess => status == 4 && token != null && token!.isNotEmpty;

  factory QrCheckResult.fromJson(Map<String, dynamic> json) {
    return QrCheckResult(
      status: asInt(json['status']) ?? 0,
      token: asString(json['token']),
      userId: asString(json['userid']),
      nickname: asString(json['nickname']),
      avatar: asString(json['pic']),
    );
  }
}

/// 微信扫码登录轮询结果（微信长轮询接口透传，状态语义与酷狗自有码不同）。
class WxQrCheckResult {
  const WxQrCheckResult({required this.wxErrcode, this.wxCode});

  final int wxErrcode;
  final String? wxCode;

  // 微信扫码状态码（open.weixin.qq.com qrconnect 协议）：
  //   408 = 等待扫码      404 = 已扫码待确认      403 = 用户拒绝授权
  //   405 = 确认成功（此时携带 wx_code，用于 /login/openplat 换酷狗会话）
  //   402 = 二维码已过期
  bool get isWaitingForScan => wxErrcode == 408;
  bool get isWaitingForConfirm => wxErrcode == 404;
  bool get isRefused => wxErrcode == 403;
  bool get isExpired => wxErrcode == 402;
  bool get isConfirmed =>
      wxErrcode == 405 && wxCode != null && wxCode!.isNotEmpty;

  factory WxQrCheckResult.fromJson(Map<String, dynamic> json) {
    return WxQrCheckResult(
      wxErrcode: asInt(json['wx_errcode']) ?? -1,
      wxCode: asString(json['wx_code']),
    );
  }
}
