// 启动恢复与开机自启播放的竞态回归：构造函数 unawaited 发起的
// _restorePlaybackState 在冷启动磁盘繁忙（prefs 首次加载慢）时可能晚于
// 首页 _checkAndAutoPlay 的每日推荐起播。修复前恢复会用上次队列整队覆盖
// 在播会话（queue/currentSong/洗牌状态），后果按恢复落地时机分三种：
// A) 首曲播放中落地 → 曲末切回上次队列（内容错乱）；
// B) 曲末切歌在途落地 → 切歌被「已切歌」守卫放弃，停在曲尾不再前进
//    （用户实测：随机播放播完一首即自动暂停）；
// C) 首曲解析在途落地 → 起播被放弃，开机自启整体失效。
// 修复：恢复检测到在播会话（currentSong 非空）时只恢复播放模式偏好，
// 洗牌队列按在播队列原位重建；首页消费前 await startupRestored 消除竞态。
//
// 另含无竞态的基线：恢复完成后走 daily 分支，随机/列表循环曲末正常前进。
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';

/// 可控延时的 SharedPreferences store：首次 getAll() 挂在 Completer 上，
/// 模拟实机慢速 prefs 加载（_restorePlaybackState 晚于每日推荐起播完成）。
class _GatedPrefsStore extends SharedPreferencesStorePlatform {
  _GatedPrefsStore(this._gate, Map<String, Object> values)
      : _values = Map<String, Object>.of(values);

  final Completer<void> _gate;
  final Map<String, Object> _values;
  bool _released = false;

  Future<void> _maybeWait() async {
    if (!_released) {
      _released = true;
      await _gate.future;
    }
  }

  @override
  Future<bool> clear() async {
    _values.clear();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async {
    await _maybeWait();
    return Map<String, Object>.of(_values);
  }

  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _values[key] = value;
    return true;
  }

  static void install(Completer<void> gate, Map<String, Object> values) {
    // 复位单例缓存（setUp 的 setMockInitialValues 可能已触发一次加载并把
    // SharedPreferences._completer 钉在已完成的 InMemory store 上，绕过门控）
    // 并换上带 flutter. 前缀的受控 store。
    SharedPreferences.setMockInitialValues({});
    final prefixed = <String, Object>{
      for (final e in values.entries) 'flutter.${e.key}': e.value,
    };
    SharedPreferencesStorePlatform.instance = _GatedPrefsStore(gate, prefixed);
  }
}

class _Engine {
  bool playing = false;
  ProcessingState state = ProcessingState.idle;
  Duration position = Duration.zero;
  final stateCtrl = StreamController<PlayerState>.broadcast();
  final processingCtrl = StreamController<ProcessingState>.broadcast();
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration?>.broadcast();
  final errorCtrl = StreamController<PlayerException>.broadcast();

  void emit() {
    processingCtrl.add(state);
    stateCtrl.add(PlayerState(playing, state));
  }

  void setState(ProcessingState s) {
    state = s;
    emit();
  }

  void emitPosition(Duration p) {
    position = p;
    positionCtrl.add(p);
  }

  void emitDuration(Duration? d) => durationCtrl.add(d);

  Future<void> dispose() async {
    await stateCtrl.close();
    await processingCtrl.close();
    await positionCtrl.close();
    await durationCtrl.close();
    await errorCtrl.close();
  }
}

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  _FakeAudioPlayer(this.engine);

  final _Engine engine;

  @override
  Stream<Duration> get positionStream => engine.positionCtrl.stream;

  @override
  Stream<Duration?> get durationStream => engine.durationCtrl.stream;

  @override
  Stream<PlayerState> get playerStateStream => engine.stateCtrl.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      engine.processingCtrl.stream;

  @override
  Stream<PlayerException> get errorStream => engine.errorCtrl.stream;

  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => engine.position;

  @override
  bool get playing => engine.playing;

  @override
  ProcessingState get processingState => engine.state;

  @override
  int? get androidAudioSessionId => null;
}

class _EngineAudioHandler extends Fake implements MusicAudioHandler {
  _EngineAudioHandler(this.engine, this.player);

  final _Engine engine;
  final _FakeAudioPlayer player;

  final List<String> loadedHashes = [];

  @override
  AudioPlayer get audioPlayer => player;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  void attachVoiceSearch({
    required Future<void> Function(String query) onVoiceSearch,
  }) {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {
    engine.emitPosition(position);
    if (engine.state != ProcessingState.ready) {
      engine.setState(ProcessingState.ready);
    }
  }

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    loadedHashes.add(song.hash);
    engine.setState(ProcessingState.loading);
    engine.emitPosition(Duration.zero);
    engine.setState(ProcessingState.ready);
  }

  @override
  Future<void> play() async {
    if (engine.playing) return;
    engine.playing = true;
    if (engine.state != ProcessingState.ready) {
      engine.setState(ProcessingState.ready);
    } else {
      engine.emit();
    }
  }

  @override
  Future<void> pause() async {
    if (!engine.playing) return;
    engine.playing = false;
    engine.emit();
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
  /// 每次解析前回调（测试用来挂起特定调用）。
  Future<void> Function()? gate;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    final hook = gate;
    if (hook != null) await hook();
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song(int index) => Song(
      id: 'song_$index',
      title: '歌曲$index',
      artist: '歌手$index',
      hash: 'hash_$index',
      duration: const Duration(seconds: 300),
    );

Future<void> settle([int rounds = 20]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Engine engine;
  late _FakeAudioPlayer player;
  late _EngineAudioHandler handler;
  late PlayerController controller;

  setUp(() {
    // 上次会话：旧队列 5 首 + 随机播放模式持久化。
    final oldQueue = List.generate(5, _song);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'playback_state': jsonEncode({
        'queue': oldQueue.map((s) => s.toCache()).toList(),
        'currentIndex': 2,
        'playbackMode': 'shuffle',
      }),
    });
    engine = _Engine();
    player = _FakeAudioPlayer(engine);
    handler = _EngineAudioHandler(engine, player);
    controller = PlayerController(_MockMusicApi(), handler);
  });

  tearDown(() async {
    await settle();
    controller.dispose();
    await engine.dispose();
  });

  test('每日推荐自启 + 随机模式：播完第一首自动切下一首', () async {
    // 等待 _restorePlaybackState 完成（恢复旧队列与 shuffle 模式）。
    await settle();
    expect(controller.hasRestoredPlaybackState, isTrue);
    expect(controller.playbackMode, PlaybackMode.shuffle);

    // 首页 _checkAndAutoPlay 的 daily 分支：推荐列表整体替换队列，播首曲。
    final daily = List.generate(6, (i) => _song(100 + i));
    await controller.playSong(daily.first, queue: daily);
    await settle();
    engine.emitDuration(const Duration(seconds: 300));
    engine.emitPosition(const Duration(seconds: 1));
    await settle();
    expect(controller.isPlaying, isTrue, reason: '前置：第一首应在播放');
    expect(controller.queue, same(daily));

    // 自然播完。
    engine.emitPosition(const Duration(seconds: 300));
    engine.setState(ProcessingState.completed);
    await settle();

    expect(
      handler.loadedHashes.length,
      greaterThan(1),
      reason: '随机模式下播完一首应切到另一首（loadedHashes 出现新 hash）',
    );
    expect(handler.loadedHashes.last, isNot(equals(daily.first.hash)),
        reason: '切到的下一首不应还是第一首');
    expect(controller.isPlaying, isTrue, reason: '切歌后应继续播放');
  });

  test('每日推荐自启 + 列表循环（对照）：播完第一首自动切下一首', () async {
    await settle();
    // 对照组：列表循环下同样的启动路径行为正常（用户反馈仅随机模式异常）。
    controller.playbackMode = PlaybackMode.playlistLoop;

    final daily = List.generate(6, (i) => _song(200 + i));
    await controller.playSong(daily.first, queue: daily);
    await settle();
    engine.emitDuration(const Duration(seconds: 300));
    engine.emitPosition(const Duration(seconds: 1));
    await settle();
    expect(controller.isPlaying, isTrue, reason: '前置：第一首应在播放');

    engine.emitPosition(const Duration(seconds: 300));
    engine.setState(ProcessingState.completed);
    await settle();

    expect(handler.loadedHashes, contains(daily[1].hash),
        reason: '列表循环应播第二首');
    expect(controller.isPlaying, isTrue);
  });

  // 竞态 A：prefs 恢复慢（冷启动磁盘繁忙），每日推荐已起播第一首后
  // _restorePlaybackState 才完成 —— 修复后恢复不得覆盖在播会话：
  // 只恢复播放模式偏好并按在播队列原位重建洗牌，曲末仍在推荐队列内前进。
  test('竞态A：恢复晚到（第一首播放中），不覆盖在播会话，曲末仍前进', () async {
    final gate = Completer<void>();
    final oldQueue = List.generate(5, _song);
    _GatedPrefsStore.install(
      gate,
      {
        'playback_state': jsonEncode({
          'queue': oldQueue.map((s) => s.toCache()).toList(),
          'currentIndex': 2,
          'playbackMode': 'shuffle',
        }),
      },
    );

    final raceEngine = _Engine();
    final racePlayer = _FakeAudioPlayer(raceEngine);
    final raceHandler = _EngineAudioHandler(raceEngine, racePlayer);
    final raceController = PlayerController(_MockMusicApi(), raceHandler);

    // 首页 postFrame + delayed(0)：prefs 尚未加载完即触发每日推荐起播。
    final daily = List.generate(6, (i) => _song(300 + i));
    await raceController.playSong(daily.first, queue: daily);
    await settle();
    raceEngine.emitDuration(const Duration(seconds: 300));
    raceEngine.emitPosition(const Duration(seconds: 1));
    await settle();
    expect(raceController.isPlaying, isTrue, reason: '前置：第一首已在播');

    // 慢速 prefs 此刻才完成加载。
    gate.complete();
    await settle();
    expect(raceController.hasRestoredPlaybackState, isTrue);
    // 修复点：currentSong/queue 不得被上次队列覆盖。
    expect(raceController.currentSong?.hash, daily.first.hash,
        reason: '恢复不得覆盖在播的推荐首曲');
    expect(raceController.queue, same(daily), reason: '恢复不得整队覆盖推荐队列');
    expect(raceController.playbackMode, PlaybackMode.shuffle,
        reason: '播放模式偏好仍应恢复');

    // 第一首自然播完：洗牌模式按在播队列原位重建后应继续前进。
    raceEngine.emitPosition(const Duration(seconds: 300));
    raceEngine.setState(ProcessingState.completed);
    await settle();

    expect(raceHandler.loadedHashes.length, 2, reason: '应已切到下一首');
    expect(
      daily.any((s) => s.hash == raceHandler.loadedHashes.last),
      isTrue,
      reason: '切到的下一首应仍在每日推荐队列内（而非上次队列）',
    );
    expect(raceController.isPlaying, isTrue, reason: '切歌后应继续播放');
  });

  // 竞态 B：恢复恰好落在第一首播完、下一首地址解析在途的窗口 ——
  // 修复前恢复覆盖 currentSong，在途切歌被「解析期间已切歌」守卫放弃，
  // 队列停在曲尾（用户实测：随机播放播完一首即停）。
  test('竞态B：恢复落在切歌在途窗口，切歌不被放弃', () async {
    final gate = Completer<void>();
    final oldQueue = List.generate(5, _song);
    _GatedPrefsStore.install(
      gate,
      {
        'playback_state': jsonEncode({
          'queue': oldQueue.map((s) => s.toCache()).toList(),
          'currentIndex': 2,
          'playbackMode': 'shuffle',
        }),
      },
    );

    // 首次 songUrl（第一首）放行；此后所有解析（下一首/预取）统一挂起，
    // 等恢复先落地 —— 模拟「切歌在途窗口」。
    final urlGate = Completer<void>();
    var urlCalls = 0;
    final gatedApi = _MockMusicApi();
    gatedApi.gate = () async {
      urlCalls++;
      if (urlCalls > 1) await urlGate.future;
    };

    final raceEngine = _Engine();
    final racePlayer = _FakeAudioPlayer(raceEngine);
    final raceHandler = _EngineAudioHandler(raceEngine, racePlayer);
    final raceController = PlayerController(gatedApi, raceHandler);

    final daily = List.generate(6, (i) => _song(400 + i));
    await raceController.playSong(daily.first, queue: daily);
    await settle();
    raceEngine.emitDuration(const Duration(seconds: 300));
    raceEngine.emitPosition(const Duration(seconds: 1));
    await settle();
    expect(raceController.isPlaying, isTrue);

    // 第一首播完 → 完成处理 → 解析下一首地址（挂起中）。
    raceEngine.emitPosition(const Duration(seconds: 300));
    raceEngine.setState(ProcessingState.completed);
    await settle();

    // 恢复此刻落地（修复后为「不覆盖在播会话」分支）。
    gate.complete();
    await settle();

    // 放行地址解析：切歌应照常完成，而非被「已切歌」守卫放弃。
    urlGate.complete();
    await settle();

    expect(raceHandler.loadedHashes.length, 2, reason: '曲末切歌应完成加载');
    expect(raceController.isPlaying, isTrue, reason: '切歌后应继续播放（不停在曲尾）');
    expect(
      daily.any((s) => s.hash == raceHandler.loadedHashes.last),
      isTrue,
      reason: '下一首应仍在每日推荐队列内',
    );
  });

  // 竞态 C：恢复落在第一首地址解析在途 —— 修复前 currentSong 被覆盖，
  // 起播被「解析期间已切歌」守卫放弃，开机自启整体失效（一声不出）。
  test('竞态C：恢复落在首曲起播在途，起播不被放弃', () async {
    final gate = Completer<void>();
    final urlGate = Completer<void>();
    final oldQueue = List.generate(5, _song);
    _GatedPrefsStore.install(
      gate,
      {
        'playback_state': jsonEncode({
          'queue': oldQueue.map((s) => s.toCache()).toList(),
          'currentIndex': 2,
          'playbackMode': 'shuffle',
        }),
      },
    );

    // 第一次 songUrl（首曲）即挂起。
    final gatedApi = _MockMusicApi();
    gatedApi.gate = () => urlGate.future;

    final raceEngine = _Engine();
    final racePlayer = _FakeAudioPlayer(raceEngine);
    final raceHandler = _EngineAudioHandler(raceEngine, racePlayer);
    final raceController = PlayerController(gatedApi, raceHandler);

    final daily = List.generate(6, (i) => _song(500 + i));
    final playFuture = raceController.playSong(daily.first, queue: daily);
    await settle();

    // 恢复在首曲解析在途时落地。
    gate.complete();
    await settle();

    // 放行首曲解析：起播应照常完成。
    urlGate.complete();
    await playFuture;
    await settle();
    raceEngine.emitDuration(const Duration(seconds: 300));
    raceEngine.emitPosition(const Duration(seconds: 1));
    await settle();

    expect(raceHandler.loadedHashes, [daily.first.hash],
        reason: '首曲应完成加载（不被恢复竞态放弃）');
    expect(raceController.isPlaying, isTrue);
    expect(raceController.queue, same(daily), reason: '队列应保持推荐列表');
    expect(raceController.playbackMode, PlaybackMode.shuffle);
  });
}
