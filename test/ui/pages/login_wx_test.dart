// 微信扫码登录（默认 tab）流程测试：拉码/轮询状态流转/openplat 换会话/过期重试。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/login_page.dart';

class _FakeAuthController extends ChangeNotifier implements AuthController {
  int sessionLogins = 0;
  LoginSession? lastSession;

  @override
  Future<void> loginWithSession(
    LoginSession session, {
    bool forceRefresh = false,
  }) async {
    sessionLogins++;
    lastSession = session;
  }

  @override
  bool isRestoring = false;
  @override
  bool get isLoggedIn => false;
  @override
  String? errorMessage;
  @override
  bool isLoading = false;

  @override
  bool isLiked(Song song) => false;
  @override
  Future<void> toggleLike(Song song) async {}
  @override
  List<PlaylistSummary> get createdPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedPlaylists => const [];
  @override
  List<PlaylistSummary> get collectedAlbums => const [];
  @override
  PlaylistSummary? get likedPlaylist => null;
  @override
  int get likedCount => 0;
  @override
  UserProfile? get profile => null;
  @override
  UserVipInfo? get vipInfo => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMusicApi implements MusicApi {
  int wxQrCalls = 0;
  int wxCheckCalls = 0;
  final openplatCodes = <String>[];
  bool failOpenplat = false;

  /// 轮询返回值工厂：按序消耗，耗尽后重复最后一个。
  final wxResults = <WxQrCheckResult>[const WxQrCheckResult(wxErrcode: 408)];
  int _resultIndex = 0;

  WxQrCheckResult _nextResult() {
    final result = wxResults[_resultIndex.clamp(0, wxResults.length - 1)];
    if (_resultIndex < wxResults.length - 1) _resultIndex++;
    return result;
  }

  @override
  Future<QrCodeInfo> createWxLoginQr() async {
    wxQrCalls++;
    return QrCodeInfo(
      key: 'wx_$wxQrCalls',
      imageUrl:
          'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
  }

  @override
  Future<WxQrCheckResult> checkWxLoginStatus(String uuid) async {
    wxCheckCalls++;
    return _nextResult();
  }

  @override
  Future<LoginSession> loginByWxOpenplat(String code) async {
    openplatCodes.add(code);
    if (failOpenplat) {
      throw Exception('wx_code 已被使用');
    }
    return const LoginSession(userId: '777', token: 'token_wx', t1: 't1_wx');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_FakeMusicApi> _pumpLoginPage(
  WidgetTester tester, {
  _FakeAuthController? auth,
}) async {
  final api = _FakeMusicApi();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LoginPage(auth: auth ?? _FakeAuthController(), api: api),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('默认 tab 为微信扫码：进页即拉码并展示二维码', (tester) async {
    final api = await _pumpLoginPage(tester);

    expect(find.text('微信登录'), findsOneWidget);
    expect(api.wxQrCalls, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('请使用微信扫一扫'), findsOneWidget);
  });

  testWidgets('轮询状态流转：等待→已扫码待确认；确认后 openplat 换会话', (tester) async {
    final auth = _FakeAuthController();
    final api = await _pumpLoginPage(tester, auth: auth);

    // 已扫码待确认
    api.wxResults[0] = const WxQrCheckResult(wxErrcode: 404);
    api._resultIndex = 0;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('扫码成功，请在手机上确认'), findsOneWidget);

    // 手机端确认成功：拿 wx_code 调 openplat，构建 LoginSession 走 loginWithSession
    api.wxResults[0] = const WxQrCheckResult(wxErrcode: 405, wxCode: 'wxcode1');
    api._resultIndex = 0;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(api.openplatCodes, ['wxcode1']);
    expect(auth.sessionLogins, 1);
    expect(auth.lastSession?.token, 'token_wx');
    expect(auth.lastSession?.t1, 't1_wx');
  });

  testWidgets('二维码过期停止轮询，手动刷新拉新码', (tester) async {
    final api = await _pumpLoginPage(tester);

    api.wxResults[0] = const WxQrCheckResult(wxErrcode: 402);
    api._resultIndex = 0;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('二维码已过期，点击刷新'), findsOneWidget);
    expect(find.text('刷新二维码'), findsOneWidget);

    // 过期后不再轮询
    final checksAfterExpire = api.wxCheckCalls;
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(api.wxCheckCalls, checksAfterExpire);

    // 手动刷新：拉新码并恢复轮询
    await tester.tap(find.text('刷新二维码'));
    await tester.pumpAndSettle();
    expect(api.wxQrCalls, 2);
    expect(find.text('请使用微信扫一扫'), findsOneWidget);
  });

  testWidgets('openplat 失败（wx_code 已消耗）置过期态走整段重拉', (tester) async {
    final auth = _FakeAuthController();
    final api = await _pumpLoginPage(tester, auth: auth);
    api.failOpenplat = true;

    api.wxResults[0] = const WxQrCheckResult(wxErrcode: 405, wxCode: 'wxcode1');
    api._resultIndex = 0;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(api.openplatCodes, ['wxcode1']);
    expect(auth.sessionLogins, 0);
    expect(find.text('登录失败，点击刷新重试'), findsOneWidget);

    // 轮询已停：不会再消耗新的 openplat 调用
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(api.openplatCodes, ['wxcode1']);

    // 手动刷新重新拉码（先关掉失败详情对话框，刷新按钮才可点）
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新二维码'));
    await tester.pumpAndSettle();
    expect(api.wxQrCalls, 2);
  });

  testWidgets('拒绝授权停止轮询并提示刷新', (tester) async {
    final api = await _pumpLoginPage(tester);

    api.wxResults[0] = const WxQrCheckResult(wxErrcode: 403);
    api._resultIndex = 0;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('您拒绝了授权，点击刷新'), findsOneWidget);
    expect(find.text('刷新二维码'), findsOneWidget);
  });
}
