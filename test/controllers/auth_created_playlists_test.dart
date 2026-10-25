import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/auth_controller.dart';
import 'package:shiyin_music/core/api_client_interface.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/cache_service.dart';
import 'package:shiyin_music/services/music_api.dart';

/// 「我创建的歌单」分组测试：系统「默认收藏」(is_def=1，0 首且不可删)
/// 必须隐藏；「我喜欢」、普通自建、收藏歌单各归其位。
class _NoopClient implements ApiClientInterface {
  @override
  String? token;
  @override
  String? t1;
  @override
  String? sessionId;

  @override
  Future<dynamic> get(
    String path, [
    Map<String, Object?> query = const {},
  ]) async => throw UnimplementedError(path);

  @override
  Future<dynamic> getRaw(Uri uri) async => throw UnimplementedError();

  @override
  Future<dynamic> post(
    String path, {
    Map<String, Object?> query = const {},
    Map<String, Object?>? body,
  }) async => throw UnimplementedError(path);

  @override
  void close() {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('createdPlaylists 隐藏系统默认收藏，保留普通自建与我喜欢', () {
    final auth = AuthController(MusicApi(_NoopClient()), CacheService());
    addTearDown(auth.dispose);
    auth.playlists = const [
      PlaylistSummary(id: 'liked', title: '我喜欢', isDefault: 2, type: 0),
      PlaylistSummary(id: 'sysdef', title: '默认收藏', isDefault: 1, type: 0),
      PlaylistSummary(id: 'mine', title: '我的歌单', isDefault: 0, type: 0),
      PlaylistSummary(id: 'collected', title: '收藏的歌单', isDefault: 0, type: 1),
    ];

    final created = auth.createdPlaylists;
    // 「我喜欢」由 isCreatedPlaylist 排除（红心歌单单独展示），改动前后行为一致
    expect(created.map((p) => p.id), ['mine']);
    expect(created.any((p) => p.isSystemDefaultCollect), isFalse);

    // 默认收藏也不落入「我收藏的歌单」分组
    final collected = auth.collectedPlaylists;
    expect(collected.map((p) => p.id), ['collected']);

    // 红心同步依赖的 likedPlaylist 仍取到「我喜欢」
    expect(auth.likedPlaylist?.id, 'liked');
  });

  test('createdPlaylists 无标题兜底：名为「默认收藏」的歌单同样隐藏', () {
    final auth = AuthController(MusicApi(_NoopClient()), CacheService());
    addTearDown(auth.dispose);
    auth.playlists = const [
      PlaylistSummary(id: 'sysdef-name', title: '默认收藏', type: 0),
      PlaylistSummary(id: 'mine', title: '我的歌单', type: 0),
    ];

    expect(auth.createdPlaylists.map((p) => p.id), ['mine']);
  });
}
