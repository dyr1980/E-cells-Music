// 多账号：保存列表维护（登录入列/排序）、restore 迁移与回退、切换、
// 移除（含自动切换）、退出即移除、登录失败不动当前会话（添加账号回归）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/core/api_client.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 多账号假客户端：按 path 路由登录/资料/VIP 端点；当前身份由客户端
/// token 反查（setSession 写入什么 token，就按对应账号取数/派生刷新）。
class _MultiAccountClient implements ApiClientInterface {
  /// 非空时 /login/cellphone 抛出（模拟验证码错误）。
  Object? cellphoneError;

  final posts = <String>[];

  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  static const _tokenToUid = <String, String>{
    'token-a': 'u1',
    'token-a-r': 'u1',
    'token-b': 'u2',
    'token-b-r': 'u2',
  };

  String get _uid => _tokenToUid[token ?? ''] ?? 'u1';

  @override
  Future<dynamic> get(
    String path, [
    Map<String, Object?> query = const {},
  ]) async {
    switch (path) {
      case '/user/detail':
        return {'userid': _uid, 'nickname': 'nick-$_uid', 'pic': ''};
      case '/user/vip/detail':
        return {'status': 1};
      case '/user/playlist':
        return {'userid': _uid, 'info': <Map<String, dynamic>>[]};
      case '/youth/month/vip/record':
        // 今日已领（svip）→ 短路，不再触发 dailyVip/upgrade 的 1s 等待
        return {
          'status': 1,
          'month': '2026-10',
          'list': [
            {
              'day': DateTime.now().toIso8601String().split('T').first,
              'receive_vip': 1,
              'vip_type': 'svip',
            },
          ],
        };
      default:
        throw ArgumentError('unexpected GET $path');
    }
  }

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async {
    posts.add(path);
    switch (path) {
      case '/login/cellphone':
        if (cellphoneError != null) throw cellphoneError!;
        return {'status': 1, 'userid': 'u1', 'token': 'token-a', 't1': 't1-a'};
      case '/login/token':
        final suffix = _uid == 'u1' ? 'a' : 'b';
        return {
          'status': 1,
          'userid': _uid,
          'token': 'token-$suffix-r',
          't1': 't1-$suffix-r',
        };
      case '/login/logout':
        return {'status': 1};
      default:
        throw ArgumentError('unexpected POST $path');
    }
  }

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();
  @override
  void close() {}
}

const _u1Session = LoginSession(
  userId: 'u1',
  token: 'token-a',
  t1: 't1-a',
  nickname: '甲',
);
const _u2Session = LoginSession(
  userId: 'u2',
  token: 'token-b',
  t1: 't1-b',
  nickname: '乙',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('登录入列', () {
    test('loginWithSession 后账号进入保存列表，最近登录在前', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      // 直接走登录路径（不经 restore）：手动对齐 restore 完成后的状态
      auth.isRestoring = false;

      await auth.loginWithSession(_u1Session);
      expect(auth.savedAccounts.map((a) => a.userId), ['u1']);

      await auth.loginWithSession(_u2Session);
      expect(auth.savedAccounts.map((a) => a.userId), ['u2', 'u1']);
      // 昵称以 refreshProfile 拉到的真实资料为准（会话昵称作初始兜底）
      expect(auth.savedAccounts.last.nickname, 'nick-u1');
    });

    test('login() 成功同样入列', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;

      auth.isRestoring = false;
      final result = await auth.login('13800138000', '123456');
      expect(result?.requiresUserSelection, isFalse);
      expect(auth.savedAccounts.map((a) => a.userId), ['u1']);
    });
  });

  group('restore', () {
    test('存量单账号：恢复入列并迁移旧全局红心键到按用户键', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'shiyin_token': 'token-a',
        'shiyin_t1': 't1-a',
        'shiyin_session_id': '',
        'shiyin_user_id': 'u1',
        'shiyin_liked_hashes': '["h1","h2"]',
        'shiyin_liked_fileids': '{}',
      });
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;

      await auth.restore();

      expect(auth.isLoggedIn, isTrue);
      expect(auth.savedAccounts.any((a) => a.userId == 'u1'), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shiyin_liked_hashes_u1'), '["h1","h2"]');
      expect(prefs.getString('shiyin_liked_hashes'), isNull);
      expect(prefs.getString('shiyin_liked_fileids'), isNull);
      expect(
        auth.isLiked(const Song(id: '1', title: 't', artist: 'a', hash: 'h1')),
        isTrue,
      );
    });

    test('活动键无效时回退到最近使用的保存账号，不迁移旧全局红心键', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'shiyin_saved_accounts': jsonEncode([
          {
            'userId': 'u2',
            'nickname': '乙',
            'token': 'token-b',
            't1': 't1-b',
            'lastUsedAt': 2000,
          },
          {
            'userId': 'u1',
            'nickname': '甲',
            'token': 'token-a',
            't1': 't1-a',
            'lastUsedAt': 1000,
          },
        ]),
        // 旧全局键归属不明：回退路径不得把它读给 u2
        'shiyin_liked_hashes': '["h9"]',
      });
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;

      await auth.restore();

      expect(auth.session?.userId, 'u2');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shiyin_user_id'), 'u2');
      expect(prefs.getString('shiyin_liked_hashes_u2'), isNull);
      expect(prefs.getString('shiyin_liked_hashes'), '["h9"]');
    });
  });

  group('switchAccount', () {
    test('切换到目标账号：会话/凭据替换、列表重排、forceRefresh 生效', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.loginWithSession(_u1Session);
      await auth.loginWithSession(_u2Session);

      final ok = await auth.switchAccount('u1');

      expect(ok, isTrue);
      expect(auth.session?.userId, 'u1');
      // 切换强制走一次 /login/token 并采纳刷新后的 token
      expect(client.posts, contains('/login/token'));
      expect(client.token, 'token-a-r');
      expect(auth.savedAccounts.first.userId, 'u1');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shiyin_user_id'), 'u1');
    });

    test('同账号/未知账号返回 false，不做请求', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.loginWithSession(_u1Session);
      client.posts.clear();

      expect(await auth.switchAccount('u1'), isFalse);
      expect(await auth.switchAccount('unknown'), isFalse);
      expect(client.posts, isEmpty);
    });

    test('切换后内存红心不串号（u1 的红心不带入 u2）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'shiyin_token': 'token-a',
        'shiyin_t1': 't1-a',
        'shiyin_session_id': '',
        'shiyin_user_id': 'u1',
        'shiyin_liked_hashes_u1': '["h1"]',
        'shiyin_liked_fileids_u1': '{}',
        'shiyin_saved_accounts': jsonEncode([
          {
            'userId': 'u2',
            'nickname': '乙',
            'token': 'token-b',
            't1': 't1-b',
            'lastUsedAt': 2000,
          },
        ]),
      });
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.restore();
      final song = const Song(id: '1', title: 't', artist: 'a', hash: 'h1');
      expect(auth.isLiked(song), isTrue);

      expect(await auth.switchAccount('u2'), isTrue);
      expect(auth.isLiked(song), isFalse);
    });
  });

  group('removeAccount', () {
    test('移除非当前账号：仅出列，不触发服务端登出', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.loginWithSession(_u1Session);
      await auth.loginWithSession(_u2Session);
      client.posts.clear();

      await auth.removeAccount('u1');

      expect(auth.savedAccounts.map((a) => a.userId), ['u2']);
      expect(auth.session?.userId, 'u2');
      expect(client.posts, isNot(contains('/login/logout')));
    });

    test('移除当前账号且有剩余：服务端登出 + 只清该账号数据 + 自动切换', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.loginWithSession(_u1Session);
      await auth.loginWithSession(_u2Session);
      // 切回 u1 作为当前账号，保留 u1/u2 两条
      await auth.switchAccount('u1');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cache_user_u1', '{"savedAt":1,"payload":{}}');
      await prefs.setString('cache_user_u2', '{"savedAt":1,"payload":{}}');

      await auth.removeAccount('u1');

      expect(client.posts, contains('/login/logout'));
      expect(auth.session?.userId, 'u2');
      expect(auth.savedAccounts.map((a) => a.userId), ['u2']);
      // 只清 u1 的用户级缓存，u2 的原样保留
      expect(prefs.getString('cache_user_u1'), isNull);
      expect(prefs.getString('cache_user_u2'), isNotNull);
      expect(prefs.getString('shiyin_user_id'), 'u2');
    });

    test('移除最后一个账号：完整登出回未登录态', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.loginWithSession(_u1Session);

      await auth.removeAccount('u1');

      expect(auth.isLoggedIn, isFalse);
      expect(auth.savedAccounts, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('shiyin_token'), isNull);
      expect(prefs.getString('shiyin_user_id'), isNull);
    });
  });

  group('logout（退出即移除）', () {
    test('仍有其他账号：移除当前并自动切换，保持登录', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.loginWithSession(_u1Session);
      await auth.loginWithSession(_u2Session);
      // 当前是 u2；退出后应切回 u1
      await auth.logout();

      expect(auth.isLoggedIn, isTrue);
      expect(auth.session?.userId, 'u1');
      expect(auth.savedAccounts.map((a) => a.userId), ['u1']);
      expect(client.posts, contains('/login/logout'));
    });

    test('最后一个账号：完整登出', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.loginWithSession(_u1Session);

      await auth.logout();

      expect(auth.isLoggedIn, isFalse);
      expect(auth.savedAccounts, isEmpty);
    });
  });

  group('添加账号回归', () {
    test('已有会话时 login 失败：当前会话与本地凭证原样保留', () async {
      final client = _MultiAccountClient();
      final auth = AuthController(MusicApi(client), CacheService());
      addTearDown(auth.dispose);
      auth.isRestoring = false;
      await auth.loginWithSession(_u1Session);
      expect(auth.session?.userId, 'u1');
      client.cellphoneError = ApiException('验证码错误');
      final tokenBefore = client.token;
      final prefs = await SharedPreferences.getInstance();
      final storedTokenBefore = prefs.getString('shiyin_token');

      final result = await auth.login('13800138000', '000000');

      expect(result, isNull);
      expect(auth.errorMessage, isNotNull);
      // 客户端会话未被清空（修复点：不再无条件 setSession(null)）
      expect(client.token, tokenBefore);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.session?.userId, 'u1');
      expect(prefs.getString('shiyin_token'), storedTokenBefore);
    });
  });
}
