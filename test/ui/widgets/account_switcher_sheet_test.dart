// 账号切换面板：列表渲染/当前勾选、点击切换、移除确认、loading 禁点、
// 添加账号 pop 面板并 push 登录页（添加模式）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/ui/widgets/account_switcher_sheet.dart';

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
  List<SavedAccount> savedAccounts = const [];
  @override
  UserProfile? profile;
  @override
  UserVipInfo? vipInfo;

  final switched = <String>[];
  final removed = <String>[];

  @override
  Future<bool> switchAccount(String userId) async {
    switched.add(userId);
    session = LoginSession(userId: userId, token: 't-$userId');
    notifyListeners();
    return true;
  }

  @override
  Future<void> removeAccount(String userId) async {
    removed.add(userId);
    savedAccounts = savedAccounts
        .where((a) => a.userId != userId)
        .toList();
    notifyListeners();
  }

  @override
  bool get isLoggedIn => session?.isValid == true;

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

SavedAccount _account(String uid, String nickname, {int? lastUsedAt}) =>
    SavedAccount(
      userId: uid,
      nickname: nickname,
      token: 't-$uid',
      lastUsedAt: lastUsedAt ?? 1000,
    );

Future<void> _openSheet(WidgetTester tester, _FakeAuthController auth) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showAccountSwitcherSheet(
                context,
                auth: auth,
                api: _FakeMusicApi(),
              ),
              child: const Text('打开面板'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开面板'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('渲染账号列表：当前勾选标记、UID 副标题、添加账号入口', (tester) async {
    final auth = _FakeAuthController()
      ..session = const LoginSession(userId: 'u2', token: 't2')
      ..savedAccounts = [
        _account('u2', '小乙', lastUsedAt: 2000),
        _account('u1', '小甲', lastUsedAt: 1000),
      ];
    await _openSheet(tester, auth);

    expect(find.text('切换账号'), findsOneWidget);
    expect(find.text('小乙'), findsOneWidget);
    expect(find.text('小甲'), findsOneWidget);
    expect(find.text('当前账号 · UID u2'), findsOneWidget);
    expect(find.text('UID u1'), findsOneWidget);
    expect(find.text('添加账号'), findsOneWidget);
  });

  testWidgets('点击非当前账号调用 switchAccount 并关闭面板', (tester) async {
    final auth = _FakeAuthController()
      ..session = const LoginSession(userId: 'u2', token: 't2')
      ..savedAccounts = [
        _account('u2', '小乙', lastUsedAt: 2000),
        _account('u1', '小甲', lastUsedAt: 1000),
      ];
    await _openSheet(tester, auth);

    await tester.tap(find.text('小甲'));
    await tester.pumpAndSettle();

    expect(auth.switched, ['u1']);
    // 面板已关闭（切回首页按钮可见）
    expect(find.text('切换账号'), findsNothing);
    expect(find.text('打开面板'), findsOneWidget);
  });

  testWidgets('移除账号走确认弹窗，确认后调用 removeAccount 且面板保持', (tester) async {
    final auth = _FakeAuthController()
      ..session = const LoginSession(userId: 'u2', token: 't2')
      ..savedAccounts = [
        _account('u2', '小乙', lastUsedAt: 2000),
        _account('u1', '小甲', lastUsedAt: 1000),
      ];
    await _openSheet(tester, auth);

    // 非当前账号才有移除按钮
    await tester.tap(find.byTooltip('移除账号'));
    await tester.pumpAndSettle();
    expect(find.text('移除账号'), findsOneWidget);

    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();

    expect(auth.removed, ['u1']);
    // 仍登录（还有当前账号）：面板不关，列表刷新后只剩乙
    expect(find.text('切换账号'), findsOneWidget);
    expect(find.text('小甲'), findsNothing);
  });

  testWidgets('isLoading 期间点击被忽略', (tester) async {
    final auth = _FakeAuthController()
      ..session = const LoginSession(userId: 'u2', token: 't2')
      ..savedAccounts = [
        _account('u2', '小乙', lastUsedAt: 2000),
        _account('u1', '小甲', lastUsedAt: 1000),
      ]
      ..isLoading = true;
    // isLoading 下面板有不定长进度条（永不“安定”），
    // 用定时 pump 完成入场动画而不等 settle
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showAccountSwitcherSheet(
                  context,
                  auth: auth,
                  api: _FakeMusicApi(),
                ),
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开面板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('小甲'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(auth.switched, isEmpty);
  });

  testWidgets('添加账号：关闭面板并 push 添加模式的登录页', (tester) async {
    final auth = _FakeAuthController()
      ..session = const LoginSession(userId: 'u1', token: 't1')
      ..savedAccounts = [_account('u1', '小甲')];
    await _openSheet(tester, auth);

    await tester.tap(find.text('添加账号'));
    await tester.pumpAndSettle();

    // 登录页已 push 且带返回按钮（添加账号模式）
    expect(find.text('微信登录'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
  });
}
