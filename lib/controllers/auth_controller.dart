import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../core/api_client.dart';
import '../models/music_models.dart';
import '../services/cache_service.dart';
import '../services/music_api.dart';
import '../services/network_monitor.dart';
import '../services/vip_background_task.dart';

class AuthController extends ChangeNotifier {
  AuthController(this._api, this._cacheService) {
    _vipBackgroundTask.onClaimSuccess = () => refreshProfile(silent: true);
    // 断网启动时 refreshProfile（含 VIP 状态查询）与每日 VIP 领取都会失败，
    // 且没有其他时机补跑；恢复网络后静默刷新用户数据并补跑领取任务
    // （schedule 自带当日去重，当天已领过则直接跳过）。
    _networkRestoredSub = NetworkMonitor.instance.onConnectivityRestored.listen(
      (_) {
        if (!isLoggedIn) return;
        unawaited(() async {
          await refreshProfile(silent: true);
          _vipBackgroundTask.schedule(session);
        }());
      },
    );
  }

  static const _tokenKey = 'shiyin_token';
  static const _t1Key = 'shiyin_t1';
  static const _sessionIdKey = 'shiyin_session_id';
  static const _userIdKey = 'shiyin_user_id';
  static const _playlistCachePrefix = 'shiyin_cached_playlists';
  static const _playlistEmptyCountPrefix = 'shiyin_playlist_empty_count';
  // 多账号：本机已保存账号列表（JSON，按 lastUsedAt 降序）。
  static const _savedAccountsKey = 'shiyin_saved_accounts';
  // 红心集合按用户隔离（多账号切换不得串号）。旧全局 key 仅在 restore
  // 直系恢复时做一次性迁移读取，迁移后删除。
  static const _likedHashesPrefix = 'shiyin_liked_hashes';
  static const _likedFileIdsPrefix = 'shiyin_liked_fileids';
  static const _legacyLikedHashesKey = 'shiyin_liked_hashes';
  static const _legacyLikedFileIdsKey = 'shiyin_liked_fileids';
  final MusicApi _api;
  final CacheService _cacheService;
  late final VipBackgroundTask _vipBackgroundTask = VipBackgroundTask(_api);

  /// 自动领取 VIP 任务，供设置页绑定开关 / 立即领取 / 状态展示。
  VipBackgroundTask get vipClaim => _vipBackgroundTask;

  bool isRestoring = true;
  bool isLoading = false;
  String? errorMessage;
  LoginSession? session;
  UserProfile? profile;
  UserVipInfo? vipInfo;
  List<PlaylistSummary> playlists = const [];

  /// 本机已保存账号，按 lastUsedAt 降序（首个即最近使用）。
  List<SavedAccount> savedAccounts = const [];

  final Set<String> _likedHashes = {};
  final Map<String, int> _hashToFileId = {};
  StreamSubscription<void>? _networkRestoredSub;

  /// 收藏写操作互斥链：服务端全量同步（清空重建）、单曲点赞增删、
  /// 歌单批量增删对收藏集合的写改统一串行执行，
  /// 避免并发写互相覆盖（刚点下的赞被同步的旧列表清掉）。
  Future<void> _likedMutationLock = Future.value();

  /// 入队一段已持锁的收藏集合变更。链上吞掉错误保证后续任务不被卡死；
  /// 返回原 task 供调用方感知错误（不得在已持有锁的上下文内调用）。
  Future<void> _enqueueLikedMutation(Future<void> Function() body) {
    final task = _likedMutationLock.then((_) => body());
    _likedMutationLock = task.catchError((Object _) {});
    return task;
  }

  bool get isLoggedIn => session?.isValid == true;

  bool isLiked(Song song) => _likedHashes.contains(song.hash);

  int get likedCount {
    final playlist = likedPlaylist;
    if (playlist != null && playlist.songCount != null) {
      return playlist.songCount!;
    }
    return _likedHashes.length;
  }

  /// 点赞切换（乐观更新）：
  ///
  /// 点下瞬间即翻转本地收藏状态并 [notifyListeners]，红心当帧变色；
  /// 服务端确认仍走 [_likedMutationLock] 互斥链串行，失败则回滚本地
  /// 状态并重新通知、原样 rethrow（调用方的 toast 逻辑不变）。
  ///
  /// 乐观翻转与动作快照都在同步段执行（首个 await 之前）：快速连点时
  /// 第二次读到的是已翻转后的状态，方向判定天然正确；链内只执行本次
  /// 点按快照到的动作（增 / 删），不再重新判定方向。
  Future<void> toggleLike(Song song) async {
    final playlist = likedPlaylist;
    if (playlist == null) return;

    final targetListId = playlist.listId?.isNotEmpty == true
        ? playlist.listId!
        : playlist.id;
    // 本次点按的动作快照 + 回滚所需的前态（同步段，无 await）。
    final wasLiked = _likedHashes.contains(song.hash);
    final prevFileId = _hashToFileId[song.hash];
    if (wasLiked) {
      _likedHashes.remove(song.hash);
      _hashToFileId.remove(song.hash);
    } else {
      _likedHashes.add(song.hash);
    }
    notifyListeners();

    // 服务端增删入互斥链，避免被并发的全量同步覆盖。
    final task = _likedMutationLock.then((_) async {
      try {
        Map<String, dynamic>? resp;
        if (wasLiked) {
          // fileId 来源优先级（已持有互斥锁，同步直接跑执行体）：
          // 1. 点按前快照 prevFileId（最可信；乐观段已清映射，必须用快照）；
          // 2. 无快照时先全量同步拿服务端真值，再用映射；
          //    绝不能直接信任 song.id——搜索/首页来的 Song 其 id 是
          //    MixSongID 而非 fileid，用它删服务端会静默失败，
          //    本地乐观移除在下次同步时被打回（“取消红心不生效”）。
          // 3. 同步失败才回退试 song.id（歌单页的 Song 其 id 即 fileid）。
          var fileId = prevFileId;
          if (fileId == null) {
            final synced = await _syncLikedSongsLocked();
            fileId = _hashToFileId[song.hash];
            if (fileId == null) {
              if (synced) {
                // 同步成功但服务端没有此歌：同步结果即真值（比如另一台
                // 设备已取消、或前一次点赞请求失败），保持乐观移除，
                // 不得回滚加回——否则本地与服务端永久分叉。
                notifyListeners();
                await _persistLikedHashes();
                return;
              }
              fileId = _resolvePlaylistFileId(song);
              if (fileId == null) {
                _likedHashes.add(song.hash);
                if (prevFileId != null) _hashToFileId[song.hash] = prevFileId;
                notifyListeners();
                throw Exception('无法定位歌曲在歌单中的 fileid，请下拉刷新后重试');
              }
            }
          }
          try {
            resp = await _api.removeSongsFromPlaylist(
              targetListId,
              [song],
              fileIds: [fileId],
            );
            // Rust 层业务失败不抛错（只回传 status/error_code 信封），
            // 不校验就会“本地已取消、服务端没删”，重启同步后红心回来。
            _ensurePlaylistMutationSuccess(resp, '取消收藏');
          } catch (error) {
            // 快照 fileId 可能是旧值（另一设备删后重加，fileid 已变）：
            // 同步一次拿新 fileId 重试，仍失败才走外层回滚。
            if (prevFileId != null && fileId == prevFileId) {
              final synced = await _syncLikedSongsLocked();
              final freshId = _hashToFileId[song.hash];
              if (synced && freshId == null) {
                // 与上方 fileId 缺失的主路径同语义：同步成功且服务端已无
                // 此歌——首次删除实际已生效（或另一设备已取消），同步结果
                // 即真值，保持乐观移除并落盘。此处 rethrow 会让外层回滚把
                // 红心加回，本地与服务端分叉到下次同步才收敛，且用户看到
                // 「取消失败」实为已成功。
                notifyListeners();
                await _persistLikedHashes();
                return;
              }
              if (synced && freshId != null && freshId != prevFileId) {
                resp = await _api.removeSongsFromPlaylist(
                  targetListId,
                  [song],
                  fileIds: [freshId],
                );
                _ensurePlaylistMutationSuccess(resp, '取消收藏');
                _likedHashes.remove(song.hash);
                _hashToFileId.remove(song.hash);
                _updateLikedCountFromResponse(resp);
                notifyListeners();
                await _persistLikedHashes();
                return;
              }
            }
            rethrow;
          }
          // 幂等确认（同步段已做乐观移除；期间若被全量同步重建则清掉）。
          _likedHashes.remove(song.hash);
          _hashToFileId.remove(song.hash);
        } else {
          resp = await _api.addToPlaylist(targetListId, song);
          _ensurePlaylistMutationSuccess(resp, '收藏');
          // 幂等确认（期间若被全量同步清空则补回）。
          _likedHashes.add(song.hash);
          if (resp != null) {
            final info = resp['info'];
            if (info is List && info.isNotEmpty) {
              final fid = info[0]['fileid'];
              if (fid is int) {
                _hashToFileId[song.hash] = fid;
              } else if (fid is String) {
                final parsed = int.tryParse(fid);
                if (parsed != null) _hashToFileId[song.hash] = parsed;
              }
            }
          }
        }
        _updateLikedCountFromResponse(resp);
        // 先通知再落盘：红心不经过磁盘写等待；await 的仍是完整任务。
        notifyListeners();
        await _persistLikedHashes();
      } catch (error) {
        // 服务端失败：回滚到点按前状态并通知，调用方感知原错误。
        if (wasLiked) {
          _likedHashes.add(song.hash);
          if (prevFileId != null) _hashToFileId[song.hash] = prevFileId;
        } else {
          _likedHashes.remove(song.hash);
          _hashToFileId.remove(song.hash);
        }
        notifyListeners();
        rethrow;
      }
    });
    // 链上吞掉错误，保证后续互斥任务不被前置失败卡死；调用方仍感知原错误。
    _likedMutationLock = task.catchError((Object _) {});
    await task;
  }

  PlaylistSummary? get likedPlaylist {
    for (final playlist in playlists) {
      if (playlist.isLikedPlaylist) {
        return playlist;
      }
    }
    return null;
  }

  List<PlaylistSummary> get createdPlaylists {
    // 「默认收藏」(is_def=1) 为系统歌单：0 首且不可删除，不展示在
    // 「我创建的歌单」（对齐原易格 isDefault!==true && name!=='默认收藏' 过滤）。
    // isCreatedPlaylist 已对其返回 false，collectedPlaylists 亦排除。
    return playlists
        .where(
          (playlist) => !playlist.isCollectedAlbum && playlist.isCreatedPlaylist,
        )
        .toList();
  }

  List<PlaylistSummary> get collectedPlaylists {
    return playlists
        .where(
          (playlist) =>
              !playlist.isLikedPlaylist &&
              !playlist.isCollectedAlbum &&
              !playlist.isSystemDefaultCollect &&
              !playlist.isCreatedPlaylist,
        )
        .toList();
  }

  List<PlaylistSummary> get collectedAlbums {
    return playlists.where((playlist) => playlist.isCollectedAlbum).toList();
  }

  PlaylistSummary? findUserPlaylist(PlaylistSummary playlist) {
    for (final item in playlists) {
      if (item.id == playlist.id ||
          (playlist.listId != null && item.listId == playlist.listId) ||
          (item.sourceGlobalId != null && item.sourceGlobalId == playlist.id) ||
          (playlist.sourceGlobalId != null &&
              item.sourceGlobalId == playlist.sourceGlobalId)) {
        return item;
      }
    }
    return null;
  }

  bool isPlaylistInLibrary(PlaylistSummary playlist) {
    return findUserPlaylist(playlist) != null;
  }

  bool canEditPlaylist(PlaylistSummary playlist) {
    if (!isLoggedIn) return false;
    final item = findUserPlaylist(playlist);
    if (item != null) {
      return item.canEditTracks;
    }
    final myUserId = session?.userId;
    if (myUserId != null &&
        myUserId.isNotEmpty &&
        playlist.creatorUserId != null &&
        playlist.creatorUserId!.isNotEmpty &&
        myUserId == playlist.creatorUserId) {
      return playlist.canEditTracks;
    }
    return false;
  }

  Future<void> createPlaylist(String name, {bool private = false}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    await _run(() async {
      await _api.createPlaylist(trimmed, private: private);
      playlists = await _loadUserPlaylistsWithCache();
    });
  }

  Future<void> collectPlaylist(PlaylistSummary playlist) async {
    await _run(() async {
      await _api.collectPlaylist(
        name: playlist.title,
        globalCollectionId: playlist.id,
      );
      playlists = await _loadUserPlaylistsWithCache();
    });
  }

  Future<void> deleteOrUncollectPlaylist(PlaylistSummary playlist) async {
    final target = findUserPlaylist(playlist) ?? playlist;
    if (target.isLikedPlaylist || target.isSystemDefaultCollect) {
      throw Exception(
        target.isSystemDefaultCollect
            ? '「默认收藏」为系统歌单，无法删除'
            : '「我喜欢」无法删除',
      );
    }
    final listId = _playlistListId(target);
    if (listId == null) {
      throw Exception('无法删除：缺少歌单 listid');
    }
    await _run(() async {
      await _api.deletePlaylist(listId);
      playlists = await _loadUserPlaylistsWithCache();
      await _syncLikedSongs();
    });
  }

  Future<void> addSongToPlaylist(PlaylistSummary playlist, Song song) async {
    await addSongsToPlaylist(playlist, [song]);
  }

  /// 批量添加（一次 API 请求）。
  Future<void> addSongsToPlaylist(
    PlaylistSummary playlist,
    List<Song> songs,
  ) async {
    if (songs.isEmpty) return;
    final listId = _playlistListId(playlist);
    if (listId == null) return;
    await _run(() async {
      final resp = await _api.addSongsToPlaylist(listId, songs);
      playlists = await _loadUserPlaylistsWithCache();
      if (playlist.isLikedPlaylist) {
        // 收藏集合写改入互斥链，避免与并发的全量同步互相覆盖。
        await _enqueueLikedMutation(() async {
          for (final song in songs) {
            if (song.hash.isNotEmpty) {
              _likedHashes.add(song.hash);
            }
          }
          final info = resp?['info'];
          if (info is List) {
            for (var i = 0; i < info.length && i < songs.length; i++) {
              final item = info[i];
              if (item is Map) {
                final fid = item['fileid'];
                final hash = songs[i].hash;
                if (fid is int && hash.isNotEmpty) {
                  _hashToFileId[hash] = fid;
                }
              }
            }
          }
          await _persistLikedHashes();
        });
      }
    });
  }

  Future<void> removeSongFromPlaylist(
    PlaylistSummary playlist,
    Song song,
  ) async {
    await removeSongsFromPlaylist(playlist, [song]);
  }

  /// 批量从歌单删除（一次 API 请求）。
  Future<void> removeSongsFromPlaylist(
    PlaylistSummary playlist,
    List<Song> songs,
  ) async {
    if (songs.isEmpty) return;
    final target = findUserPlaylist(playlist) ?? playlist;
    final listId = _playlistListId(target);
    if (listId == null) return;
    await _run(() async {
      if (target.isLikedPlaylist) {
        final missing = songs.any((s) => _resolvePlaylistFileId(s) == null);
        if (missing) {
          await _syncLikedSongs();
        }
      }
      final fileIds = <int>[];
      for (final song in songs) {
        final fid = _resolvePlaylistFileId(song);
        if (fid != null) fileIds.add(fid);
      }
      if (fileIds.isEmpty) {
        throw Exception('无法定位歌曲在歌单中的 fileid');
      }
      await _api.removeSongsFromPlaylist(
        listId,
        songs,
        fileIds: fileIds,
      );
      playlists = await _loadUserPlaylistsWithCache();
      if (target.isLikedPlaylist) {
        // 收藏集合写改入互斥链，避免与并发的全量同步互相覆盖。
        await _enqueueLikedMutation(() async {
          for (final song in songs) {
            _likedHashes.remove(song.hash);
            _hashToFileId.remove(song.hash);
          }
          await _persistLikedHashes();
        });
      }
    });
  }

  int? _resolvePlaylistFileId(Song song) {
    final mapped = _hashToFileId[song.hash];
    if (mapped != null && mapped != 0) {
      return mapped;
    }
    // 歌单曲目 Song.fromPlaylist 的 id 即为 fileid
    final fromId = int.tryParse(song.id);
    if (fromId != null && fromId != 0) {
      return fromId;
    }
    return null;
  }

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _loadSavedAccounts();
      final storedUserId = prefs.getString(_userIdKey);
      var restored = LoginSession(
        userId: storedUserId,
        token: prefs.getString(_tokenKey),
        t1: prefs.getString(_t1Key),
        sessionId: prefs.getString(_sessionIdKey),
      );

      // 旧全局红心键只允许「直系恢复存储会话」这一条路径迁移——
      // 保存列表回退路径无法认定其归属（可能属于任意账号），不迁移。
      var allowLegacyLiked = true;

      if (!restored.isValid) {
        // 存储会话无效但本机还有已保存账号（如异常退出留下的残缺凭证）：
        // 回退到最近使用的账号，写回活动键后走同一恢复流程。
        if (savedAccounts.isEmpty) {
          return;
        }
        restored = savedAccounts.first.toLoginSession();
        allowLegacyLiked = false;
        await prefs.setString(_tokenKey, restored.token ?? '');
        await prefs.setString(_t1Key, restored.t1 ?? '');
        await prefs.setString(_sessionIdKey, restored.sessionId ?? '');
        await prefs.setString(_userIdKey, restored.userId ?? '');
      }

      session = restored;
      _api.setSession(restored);

      try {
        final refreshed = await _api.refreshToken();
        final restoringId = restored.userId;
        if (restoringId != null &&
            restoringId.isNotEmpty &&
            refreshed.userId != null &&
            restoringId != refreshed.userId) {
          // 记录身份与 token 实际归属不一致（历史脏数据/账本串号）：token
          // 本身仍有效，以刷新结果为准继续使用；只清掉旧记录身份的保存
          // 项与用户级数据，避免脏缓存串号。旧版的全量清号在多账号下会把
          // 其他账号一并踢下线，不再采用。
          await _removeSavedAccountEntry(restoringId);
          await _clearUserData(restoringId);
        }
        session = refreshed;
        _api.setSession(refreshed);
        await prefs.setString(_tokenKey, refreshed.token ?? '');
        await prefs.setString(_t1Key, refreshed.t1 ?? '');
        await prefs.setString(_userIdKey, refreshed.userId ?? '');
      } catch (_) {
        // /login/token failed, continue with stored token
      }

      playlists = await _loadCachedPlaylists();
      await _loadLikedHashes(allowLegacyMigration: allowLegacyLiked);
      // 先读缓存的用户信息，静默刷新由 refreshProfile 完成
      final cachedProfile = await _cacheService.read<UserProfile>(
        _userCacheKey,
        decode: UserProfile.fromCache,
        ttl: AppConfig.userProfileTtl,
      );
      if (cachedProfile != null) {
        profile = cachedProfile.data;
      }
      // 存量单账号用户首次升级：恢复成功即进入保存列表（离线也入列，
      // 昵称头像待联网后由 refreshProfile 补全）。
      if (session != null) {
        await _upsertSavedAccount(session!);
      }
      // 缓存数据已就绪，立即通知 UI 显示，API 刷新在后台进行
      isRestoring = false;
      notifyListeners();
      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    } catch (error) {
      errorMessage = error.toString();
    } finally {
      isRestoring = false;
      notifyListeners();
    }
  }

  /// 删除/增删歌曲必须用数字 listid，不能用 global_collection_id。
  String? _playlistListId(PlaylistSummary playlist) {
    final raw = playlist.listId?.trim();
    if (raw != null && raw.isNotEmpty && int.tryParse(raw) != null) {
      return raw;
    }
    // 自建歌单 list_create_listid 通常等于 listid
    final source = playlist.sourceListId?.trim();
    if (source != null && source.isNotEmpty && int.tryParse(source) != null) {
      return source;
    }
    // collection_3_{userid}_{listid}_0
    final id = playlist.id;
    final m = RegExp(r'collection_\d+_\d+_(\d+)_\d+').firstMatch(id);
    if (m != null) {
      return m.group(1);
    }
    return null;
  }

  Future<void> refreshSession() async {
    if (session == null) return;
    final prefs = await SharedPreferences.getInstance();
    final storedUserId = prefs.getString(_userIdKey);
    try {
      final refreshed = await _api.refreshToken();
      if (storedUserId != null &&
          refreshed.userId != null &&
          storedUserId != refreshed.userId) {
        await _clearSession();
        return;
      }
      session = refreshed;
      _api.setSession(refreshed);
      await prefs.setString(_tokenKey, refreshed.token ?? '');
      await prefs.setString(_t1Key, refreshed.t1 ?? '');
      await prefs.setString(_userIdKey, refreshed.userId ?? '');
    } catch (_) {
      // Refresh failed, continue with existing session
    }
  }

  Future<void> sendCode(String mobile) async {
    await _run(() => _api.sendLoginCode(mobile));
  }

  /// 登录/切换统一入口。
  ///
  /// [forceRefresh] = true（账号切换）时无论 t1 是否为空都先调一次
  /// /login/token：与 [restore] 行为对齐——Rust 侧 kg_session.json 由
  /// setSession 整体替换后 vip_type/vip_token 为空，需借登录类响应的
  /// persist_login 补回；失败沿用原 catch 容忍，继续用存储 token。
  Future<void> loginWithSession(
    LoginSession session, {
    bool forceRefresh = false,
  }) async {
    await _run(() async {
      // 多账号切换/添加账号：先排空上一账号仍在收藏互斥链上的写操作
      // （否则旧账号在途的增删红心会打向新账号的服务端歌单），再重置
      // 上一账号的内存态，避免旧资料/歌单/红心串号到新账号。
      await _likedMutationLock;
      vipInfo = null;
      playlists = const [];
      _likedHashes.clear();
      _hashToFileId.clear();

      this.session = session;
      _api.setSession(session);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, session.token ?? '');
      await prefs.setString(_t1Key, session.t1 ?? '');
      // session.sessionId 可能为 null（扫码登录），但 ApiClient 内部
      // 已从登录响应 header 保存了后端的 session key，这里也持久化一份。
      await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
      await prefs.setString(_userIdKey, session.userId ?? '');

      // 扫码登录返回的 QrLoginStatusResponse 只有 token，缺少 t1。
      // 后续 /user/detail 等接口需要 t1 header 鉴权，否则会失败导致
      // profile/歌单拉取不到。这里先调 /login/token 刷新拿到 t1。
      if (forceRefresh || session.t1 == null || session.t1!.isEmpty) {
        try {
          final refreshed = await _api.refreshToken();
          if (refreshed.token != null && refreshed.token!.isNotEmpty) {
            // 合并：保留扫码返回的 nickname/avatar，用刷新结果的 token/t1
            session = LoginSession(
              userId: refreshed.userId ?? session.userId,
              token: refreshed.token,
              t1: refreshed.t1,
              sessionId: _api.clientSessionId,
              nickname: session.nickname,
              avatarUrl: session.avatarUrl,
            );
            this.session = session;
            _api.setSession(session);
            await prefs.setString(_tokenKey, session.token ?? '');
            await prefs.setString(_t1Key, session.t1 ?? '');
            await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
            await prefs.setString(_userIdKey, session.userId ?? '');
          }
        } catch (_) {
          // 刷新失败，继续用原 token
        }
      }

      // 用 session 数据构造临时 profile，UI 立即展示用户信息；
      // refreshProfile 成功后会覆盖为完整数据。
      if (session.nickname != null && session.nickname!.isNotEmpty) {
        profile = UserProfile(
          nickname: session.nickname!,
          avatarUrl: session.avatarUrl,
        );
      }

      // 登录/切换成功即进入保存列表（refreshProfile 内再用真实资料补全）
      await _upsertSavedAccount(this.session!);

      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    });
  }

  Future<PhoneLoginResult?> login(
    String mobile,
    String code, {
    String? userId,
  }) async {
    PhoneLoginResult? result;
    await _run(() async {
      // 添加账号模式（已有会话）不得清空客户端会话：短信登录失败/要求
      // 选择账号时，当前账号必须原样可用；未登录时客户端本就无会话，
      // 等价于原来的 setSession(null)。
      if (session == null) _api.setSession(null);
      result = await _api.loginWithPhone(
        mobile: mobile,
        code: code,
        userId: userId,
      );
      if (result?.requiresUserSelection == true) {
        return;
      }
      final nextSession = result!.session!;
      // 与 loginWithSession 相同的切换隔离：排空旧账号在途红心写、重置
      // 旧账号内存态。仅在确认拿到新会话后执行——失败/要求选择账号的
      // 路径不得动当前账号的内存态（否则当前账号界面瞬间空白）。
      await _likedMutationLock;
      vipInfo = null;
      playlists = const [];
      _likedHashes.clear();
      _hashToFileId.clear();
      session = nextSession;
      _api.setSession(nextSession);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey, nextSession.token ?? '');
      await prefs.setString(_t1Key, nextSession.t1 ?? '');
      // nextSession.sessionId 可能为 null，用 ApiClient 实际持有的 session key
      await prefs.setString(_sessionIdKey, _api.clientSessionId ?? '');
      await prefs.setString(_userIdKey, nextSession.userId ?? '');

      await _upsertSavedAccount(nextSession);
      await refreshProfile(silent: true);
      _vipBackgroundTask.schedule(session);
    });
    return result;
  }

  Future<void> refreshProfile({bool silent = false}) async {
    await _run(() async {
      profile = await _api.userDetail();
      if (profile != null) {
        // 缓存写失败（磁盘满/平台异常）不应把成功的接口结果变成登录
        // 错误：吞掉即可，下次刷新重写。
        try {
          await _cacheService.write(_userCacheKey, profile!.toCache());
        } catch (_) {}
      }
      try {
        vipInfo = await _api.userVipDetail();
      } catch (_) {
        vipInfo = null;
      }
      playlists = await _loadUserPlaylistsWithCache();
      await _syncLikedSongs();
      // 已登录时顺手用真实资料补全保存列表条目（昵称/头像/最近使用时间）
      final uid = session?.userId;
      if (uid != null && uid.isNotEmpty && session != null) {
        await _upsertSavedAccount(session!, profile: profile);
      }
    }, silent: silent);
  }

  /// 切换到已保存账号。
  ///
  /// 目标不存在 / 正在忙（登录、恢复、其他切换在途）/ 已是当前账号时
  /// 返回 false。返回 true 表示当前会话已切到目标账号——资料拉取失败也
  /// 算切换完成（错误细节见 [errorMessage]，由 UI 决定如何提示；目标
  /// token 彻底失效时可先移除再重新登录）。
  Future<bool> switchAccount(String userId) async {
    if (isLoading || isRestoring) return false;
    if (session?.userId == userId) return false;
    final target = _findSavedAccount(userId);
    if (target == null) return false;
    await loginWithSession(target.toLoginSession(), forceRefresh: true);
    return session?.userId == userId;
  }

  /// 从本机移除已保存账号（「退出即移除」的移除版）：
  /// - 非当前账号：仅从列表移除；
  /// - 当前账号：尽力服务端登出（失败不阻断本地移除）+ 只清该账号的
  ///   用户级数据（不动其他账号）；还有其他账号则自动切到最近使用的，
  ///   否则走完整登出（回登录页）。
  Future<void> removeAccount(String userId) async {
    await _run(() async {
      final isCurrent = session?.userId == userId;
      await _removeSavedAccountEntry(userId);
      if (!isCurrent) {
        notifyListeners();
        return;
      }
      try {
        await _api.logout();
      } catch (_) {}
      await _clearUserData(userId);
      if (savedAccounts.isNotEmpty) {
        await _switchToMostRecentSaved();
        return;
      }
      await _fullLocalLogout();
    });
  }

  /// 退出登录（退出即移除）：从本机移除当前账号凭证；若还有其他已保存
  /// 账号则自动切换到最近使用的（不抛服务端登出错误，避免误报），否则
  /// 走完整本地登出（服务端登出错误保留原有抛出语义）。
  Future<void> logout() async {
    await _run(() async {
      Object? serverError;
      try {
        await _api.logout();
      } catch (error) {
        serverError = error;
      }
      await _removeSavedAccountEntry(session?.userId);
      if (savedAccounts.isNotEmpty) {
        await _switchToMostRecentSaved();
        return;
      }
      if (serverError != null) {
        throw serverError;
      }
      await _fullLocalLogout();
    });
  }

  void _updateLikedCountFromResponse(Map<String, dynamic>? resp) {
    if (resp == null) return;
    final count = resp['count'];
    if (count is! int) return;
    final index = playlists.indexWhere((p) => p.isLikedPlaylist);
    if (index < 0) return;
    playlists[index] = playlists[index].copyWith(songCount: count);
  }

  /// Rust 传输层业务失败不抛错（见 transport.rs：失败只 warn 并回传
  /// 原始 status/error_code 信封），Dart 必须显式校验，否则会出现
  /// “本地已翻转、服务端没写，重启同步后打回原形”的假成功。
  void _ensurePlaylistMutationSuccess(
    Map<String, dynamic>? resp,
    String action,
  ) {
    if (resp == null) return;
    final status = resp['status'];
    final errorCode = resp['error_code'] ?? resp['errcode'];
    final okStatus = status == null || status == 1 || status == 200;
    final okCode = errorCode == null || errorCode == 0;
    if (okStatus && okCode) return;
    final msg = resp['error'] ?? resp['err'] ?? resp['msg'] ?? resp['message'];
    final detail = msg is String && msg.trim().isNotEmpty
        ? '：$msg'
        : errorCode != null
        ? '（错误码 $errorCode）'
        : '';
    throw ApiException('$action失败$detail');
  }

  /// 全量同步入队入口（外部调用走互斥链）。
  Future<void> _syncLikedSongs() {
    return _enqueueLikedMutation(_syncLikedSongsLocked);
  }

  /// 全量同步执行体：只在已持有 [_likedMutationLock] 时调用
  /// （toggleLike 任务体内与 [_syncLikedSongs] 入队后各一处）。
  ///
  /// 返回是否成功应用了服务端真值：失败时内部回退到本地持久化集合并
  /// 返回 false，调用方（toggleLike 的取消收藏分支）据此区分"服务端确无
  /// 此歌"与"同步失败无法定真值"两种 fileId 缺失场景。
  Future<bool> _syncLikedSongsLocked() async {
    try {
      final playlist = likedPlaylist;
      if (playlist == null) return false;
      final songs = await _api.playlistSongs(playlist.id, fetchAll: true);
      _likedHashes.clear();
      _hashToFileId.clear();
      for (final song in songs) {
        _likedHashes.add(song.hash);
        final fid = int.tryParse(song.id);
        if (fid != null) _hashToFileId[song.hash] = fid;
      }
      await _persistLikedHashes();
      return true;
    } catch (_) {
      try {
        await _loadLikedHashes();
      } catch (_) {}
      return false;
    }
  }

  Future<void> _persistLikedHashes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_likedHashesKey, jsonEncode(_likedHashes.toList()));
    // fileId 映射同样落盘：否则重启后 _hashToFileId 为空，取消收藏时
    // 回退用 song.id（MixSongID，非 fileid）删服务端会静默失败，
    // 本地乐观移除在下次同步时被打回——“取消红心不生效”。
    try {
      await prefs.setString(
        _likedFileIdsKey,
        jsonEncode(_hashToFileId.map((k, v) => MapEntry(k, v))),
      );
    } catch (_) {}
  }

  /// 加载当前账号的红心集合（按用户键）。
  ///
  /// [allowLegacyMigration]：旧版本红心存在全局键（无用户后缀）。仅
  /// restore 直系恢复存储会话的路径允许一次性迁移——读取全局键、按用户
  /// 键回写、删除全局键；其余路径（登录/切换/回退）红心恒由服务端全量
  /// 同步重建，不读全局键（无法认定归属，避免串号给别的账号）。
  Future<void> _loadLikedHashes({bool allowLegacyMigration = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_likedHashesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          _likedHashes.addAll(list.whereType<String>());
        }
      } catch (_) {}
    }
    // 兼容老版本：没有 fileId 映射时保持空，toggleLike 会按需全量同步补齐。
    final rawIds = prefs.getString(_likedFileIdsKey);
    if (rawIds != null && rawIds.isNotEmpty) {
      try {
        final map = jsonDecode(rawIds);
        if (map is Map) {
          map.forEach((key, value) {
            if (key is! String || key.isEmpty) return;
            if (value is int && value != 0) {
              _hashToFileId[key] = value;
            } else if (value is String) {
              final parsed = int.tryParse(value);
              if (parsed != null && parsed != 0) _hashToFileId[key] = parsed;
            }
          });
        }
      } catch (_) {}
    }

    if (!allowLegacyMigration) return;
    // 一次性迁移：按用户键已有数据则以新键为准（全局键仅作缺位兜底）
    final legacyRaw = prefs.getString(_legacyLikedHashesKey);
    final legacyIds = prefs.getString(_legacyLikedFileIdsKey);
    if (legacyRaw == null && legacyIds == null) return;
    if (raw == null || raw.isEmpty) {
      try {
        final list = jsonDecode(legacyRaw ?? '[]');
        if (list is List) {
          _likedHashes.addAll(list.whereType<String>());
        }
      } catch (_) {}
    }
    if (rawIds == null || rawIds.isEmpty) {
      try {
        final map = jsonDecode(legacyIds ?? '{}');
        if (map is Map) {
          map.forEach((key, value) {
            if (key is! String || key.isEmpty) return;
            if (value is int && value != 0) {
              _hashToFileId[key] = value;
            } else if (value is String) {
              final parsed = int.tryParse(value);
              if (parsed != null && parsed != 0) _hashToFileId[key] = parsed;
            }
          });
        }
      } catch (_) {}
    }
    await _persistLikedHashes();
    await prefs.remove(_legacyLikedHashesKey);
    await prefs.remove(_legacyLikedFileIdsKey);
  }

  Future<List<PlaylistSummary>> _loadUserPlaylistsWithCache() async {
    final prefs = await SharedPreferences.getInstance();
    final fetched = await _api.userPlaylists(pageSize: 100);

    if (fetched.isNotEmpty) {
      await prefs.setInt(_playlistEmptyCountKey, 0);
      await _saveCachedPlaylists(fetched);
      return fetched;
    }

    final emptyCount = (prefs.getInt(_playlistEmptyCountKey) ?? 0) + 1;
    await prefs.setInt(_playlistEmptyCountKey, emptyCount);

    final cached = await _loadCachedPlaylists();
    if (cached.isNotEmpty && emptyCount < 2) {
      return cached;
    }

    // 清理旧 key 与 CacheService 索引
    await prefs.remove(_playlistCacheKey);
    await _cacheService.remove(_playlistCacheKeyV2);
    return const [];
  }

  Future<List<PlaylistSummary>> _loadCachedPlaylists() async {
    // 优先读 CacheService（统一管理），回退旧 key（兼容旧版本）
    final cached = await _cacheService.read<List<PlaylistSummary>>(
      _playlistCacheKeyV2,
      decode: (json) => (json['playlists'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlaylistSummary.fromCache)
          .where((playlist) => playlist.id.isNotEmpty)
          .toList(),
      ttl: AppConfig.userProfileTtl,
    );
    if (cached != null) {
      return cached.data;
    }
    // 回退旧 key
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_playlistCacheKey);
    if (raw == null || raw.isEmpty) {
      return const [];
    }
    try {
      final json = jsonDecode(raw);
      if (json is! List) {
        return const [];
      }
      return json
          .whereType<Map>()
          .map((item) => PlaylistSummary.fromCache(asMap(item)))
          .where((playlist) => playlist.id.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveCachedPlaylists(List<PlaylistSummary> playlists) async {
    // 双写：CacheService（统一管理）+ 旧 key（兼容）
    await _cacheService.write(_playlistCacheKeyV2, {
      'playlists': playlists.map((p) => p.toCache()).toList(),
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _playlistCacheKey,
      jsonEncode(playlists.map((playlist) => playlist.toCache()).toList()),
    );
  }

  String get _playlistCacheKey {
    return '${_playlistCachePrefix}_${session?.userId ?? 'default'}';
  }

  String get _playlistEmptyCountKey {
    return '${_playlistEmptyCountPrefix}_${session?.userId ?? 'default'}';
  }

  String get _likedHashesKey =>
      '${_likedHashesPrefix}_${session?.userId ?? 'default'}';

  String get _likedFileIdsKey =>
      '${_likedFileIdsPrefix}_${session?.userId ?? 'default'}';

  String get _userCacheKey => 'cache_user_${session?.userId ?? 'default'}';

  String get _playlistCacheKeyV2 =>
      'cache_user_playlists_${session?.userId ?? 'default'}';

  // ===== 多账号：保存列表的读写与维护 =====

  /// 读取本机保存账号列表：丢弃无效条目、按 userId 去重（保留 lastUsedAt
  /// 较新者）、按 lastUsedAt 降序（首个即最近使用）。
  Future<void> _loadSavedAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_savedAccountsKey);
    if (raw == null || raw.isEmpty) {
      savedAccounts = const [];
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        savedAccounts = const [];
        return;
      }
      final byUid = <String, SavedAccount>{};
      for (final item in decoded.whereType<Map>()) {
        final account = SavedAccount.fromJson(asMap(item));
        if (!account.isValid) continue;
        final existing = byUid[account.userId];
        if (existing == null || account.lastUsedAt >= existing.lastUsedAt) {
          byUid[account.userId] = account;
        }
      }
      savedAccounts = byUid.values.toList()
        ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    } catch (_) {
      // 列表损坏按空处理，不阻断启动
      savedAccounts = const [];
    }
  }

  Future<void> _persistSavedAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _savedAccountsKey,
      jsonEncode(savedAccounts.map((a) => a.toJson()).toList()),
    );
  }

  SavedAccount? _findSavedAccount(String userId) {
    for (final account in savedAccounts) {
      if (account.userId == userId) return account;
    }
    return null;
  }

  /// 登录/切换成功后写入保存列表（按 userId 合并）：
  /// 凭据（token/t1/sessionId）与 lastUsedAt 恒取会话新值；昵称/头像取
  /// [profile] ?? session 的非空值（refreshProfile 后用真实资料补全），
  /// 否则保留条目旧值。userId 为空的会话（理论上不存在）跳过。
  Future<void> _upsertSavedAccount(
    LoginSession session, {
    UserProfile? profile,
  }) async {
    final uid = session.userId?.trim() ?? '';
    if (uid.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _findSavedAccount(uid);
    final nickname = (profile?.nickname ?? session.nickname)?.trim();
    final avatarUrl = profile?.avatarUrl ?? session.avatarUrl;
    final merged = SavedAccount(
      userId: uid,
      nickname: nickname?.isNotEmpty == true ? nickname : old?.nickname,
      avatarUrl:
          avatarUrl?.isNotEmpty == true ? avatarUrl : old?.avatarUrl,
      token: session.token ?? old?.token,
      t1: session.t1 ?? old?.t1,
      sessionId: session.sessionId ?? old?.sessionId,
      lastUsedAt: now,
    );
    savedAccounts = [...savedAccounts.where((a) => a.userId != uid), merged]
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    await _persistSavedAccounts();
  }

  Future<void> _removeSavedAccountEntry(String? userId) async {
    final uid = userId?.trim();
    if (uid == null || uid.isEmpty) return;
    savedAccounts = savedAccounts.where((a) => a.userId != uid).toList();
    await _persistSavedAccounts();
  }

  /// 清理单个账号的用户级数据（按参数 uid 构键，不依赖当前 session——
  /// 移除的可能不是当前账号）：歌单缓存旧键、空计数、按用户红心键、
  /// CacheService 用户级缓存。共享内容缓存（cache_playlist_{id} 等）不动。
  Future<void> _clearUserData(String? userId) async {
    final uid = (userId != null && userId.isNotEmpty) ? userId : 'default';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_playlistCachePrefix}_$uid');
    await prefs.remove('${_playlistEmptyCountPrefix}_$uid');
    await prefs.remove('${_likedHashesPrefix}_$uid');
    await prefs.remove('${_likedFileIdsPrefix}_$uid');
    await _cacheService.clearUserCache(uid);
  }

  /// 切到最近使用的已保存账号（登出/移除当前账号后仍有剩余时）。
  Future<void> _switchToMostRecentSaved() async {
    if (savedAccounts.isEmpty) return;
    await loginWithSession(
      savedAccounts.first.toLoginSession(),
      forceRefresh: true,
    );
  }

  /// 完整本地登出：清会话状态、4 个活动键、当前账号用户级数据与全部
  /// 用户缓存前缀（最后一个账号离场，全量清理兜底）。
  Future<void> _fullLocalLogout() async {
    // 先捕获 uid 与按用户键——清空 session 后 getter 会退到 'default'
    final uid = session?.userId;
    final playlistCacheKey = _playlistCacheKey;
    final playlistEmptyCountKey = _playlistEmptyCountKey;
    final likedHashesKey = _likedHashesKey;
    final likedFileIdsKey = _likedFileIdsKey;
    session = null;
    profile = null;
    vipInfo = null;
    playlists = const [];
    _likedHashes.clear();
    _hashToFileId.clear();
    _api.setSession(null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_t1Key);
    await prefs.remove(_sessionIdKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(playlistCacheKey);
    await prefs.remove(playlistEmptyCountKey);
    await prefs.remove(likedHashesKey);
    await prefs.remove(likedFileIdsKey);
    await _clearUserData(uid);
    await _clearSession();
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    // 按用户键先捕获——session 置空后 getter 会退到 'default' 后缀
    final playlistCacheKey = _playlistCacheKey;
    final playlistEmptyCountKey = _playlistEmptyCountKey;
    final likedHashesKey = _likedHashesKey;
    final likedFileIdsKey = _likedFileIdsKey;
    session = null;
    profile = null;
    playlists = const [];
    _likedHashes.clear();
    _hashToFileId.clear();
    _api.setSession(null);
    await prefs.remove(_tokenKey);
    await prefs.remove(_t1Key);
    await prefs.remove(_sessionIdKey);
    await prefs.remove(_userIdKey);
    await prefs.remove(playlistCacheKey);
    await prefs.remove(playlistEmptyCountKey);
    await prefs.remove(likedHashesKey);
    await prefs.remove(likedFileIdsKey);
    // 旧全局红心键一并清除，防止迁移残留
    await prefs.remove(_legacyLikedHashesKey);
    await prefs.remove(_legacyLikedFileIdsKey);
    await _cacheService.clearUserCache(null);
    notifyListeners();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool silent = false,
  }) async {
    if (!silent) {
      isLoading = true;
      errorMessage = null;
      notifyListeners();
    }

    try {
      await action();
      errorMessage = null;
    } catch (error) {
      errorMessage = _errorText(error);
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  String _errorText(Object error) {
    if (error is ApiException) {
      return error.message;
    }
    return error.toString();
  }

  @override
  void dispose() {
    _networkRestoredSub?.cancel();
    // 摘除 VIP 后台任务的成功回调：VipBackgroundTask 由 PlayerController
    // 长期持有，不摘除的话本控制器销毁后领取成功仍会调 refreshProfile →
    // notifyListeners（对已 dispose 的 ChangeNotifier）。
    _vipBackgroundTask.onClaimSuccess = null;
    super.dispose();
  }
}
