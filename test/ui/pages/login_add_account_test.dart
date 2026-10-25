// 登录页添加账号模式：仅该模式显示返回按钮、返回可退出、
// 新账号登录被采纳（活跃 userId 变化）自动 pop、同账号重登不自动退。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/pages/login_page.dart';

class _FakeAuthController extends ChangeNotifier implements AuthController {
  @override
  bool isRestoring = false;
  @override
  LoginSession? session;
  @override
  String? errorMessage;
  @override
  bool isLoading = false;
  @override
  UserProfile? profile;
  @override
  UserVipInfo? vipInfo;

  void adopt(LoginSession next) {
    session = next;
    notifyListeners();
  }

  @override
  bool get isLoggedIn => session?.isValid == true;

  @override
  Future<void> loginWithSession(
    LoginSession session, {
    bool forceRefresh = false,
  }) async {
    adopt(session);
  }

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMusicApi implements MusicApi {
  @override
  Future<QrCodeInfo> createWxLoginQr() async => const QrCodeInfo(
    key: 'wx_1',
    imageUrl:
        'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  );

  @override
  Future<WxQrCheckResult> checkWxLoginStatus(String uuid) async =>
      const WxQrCheckResult(wxErrcode: 408);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 首页带按钮 push 登录页：登录页 pop 后按钮重新可见，用于断言路由进出。
Future<_FakeAuthController> _pushLoginPage(
  WidgetTester tester, {
  required bool isAddAccount,
  _FakeAuthController? auth,
}) async {
  final fakeAuth = auth ?? _FakeAuthController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LoginPage(
                    auth: fakeAuth,
                    api: _FakeMusicApi(),
                    isAddAccount: isAddAccount,
                  ),
                ),
              ),
              child: const Text('去登录'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('去登录'));
  await tester.pumpAndSettle();
  return fakeAuth;
}

void main() {
  testWidgets('添加模式显示返回按钮', (tester) async {
    await _pushLoginPage(tester, isAddAccount: true);
    expect(find.byTooltip('返回'), findsOneWidget);
  });

  testWidgets('普通模式不显示返回按钮', (tester) async {
    await _pushLoginPage(tester, isAddAccount: false);
    expect(find.byTooltip('返回'), findsNothing);
  });

  testWidgets('返回按钮 pop 登录页回到来源页', (tester) async {
    await _pushLoginPage(tester, isAddAccount: true);

    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();

    expect(find.text('去登录'), findsOneWidget);
    expect(find.text('微信登录'), findsNothing);
  });

  testWidgets('新账号登录被采纳后自动 pop 回应用', (tester) async {
    final auth = await _pushLoginPage(
      tester,
      isAddAccount: true,
      auth: _FakeAuthController()
        ..session = const LoginSession(userId: 'u1', token: 't1'),
    );

    // 添加账号 B 成功：活跃 userId 变化 → 自动返回
    auth.adopt(const LoginSession(userId: 'u2', token: 't2'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('去登录'), findsOneWidget);
    expect(find.text('微信登录'), findsNothing);
  });

  testWidgets('同账号重登不自动 pop（用户手动返回）', (tester) async {
    final auth = await _pushLoginPage(
      tester,
      isAddAccount: true,
      auth: _FakeAuthController()
        ..session = const LoginSession(userId: 'u1', token: 't1'),
    );

    // 重登同一账号：仅 token 更新，userId 未变 → 页面保持
    auth.adopt(const LoginSession(userId: 'u1', token: 't1-new'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('微信登录'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
  });
}
