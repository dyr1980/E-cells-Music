// Android 桌面歌词（易格方案）：开启即常显 + 原生歌词引擎契约。
//
// 旧版"前台隐藏 + 回桌面自愈 + cacheLyrics 缓存"机制已随易格方案移除，
// 本文件锁定的是新契约的不变量：
//   1. 开启 = show + updateSettings + 整首歌词 loadLyrics + setPlaybackState
//      （悬浮窗常显，与前后台无关）；
//   2. 同一份歌词重复同步不重复下发（去重键），偏移调整改走 calibratePosition
//      重锚；
//   3. 切到无歌词的歌要下发空歌词表（原生不得残留上一首的句子）；
//   4. 播放进度条 seek 后下发 seekTo 重锚。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/services/music_api.dart';
import 'package:shiyin_music/services/music_audio_handler.dart';
import 'package:shiyin_music/ui/form_factor.dart';

class _FakeAudioPlayer extends Fake implements AudioPlayer {
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();
  final _playerStateController = StreamController<PlayerState>.broadcast();
  final _processingStateController =
      StreamController<ProcessingState>.broadcast();
  final _errorController = StreamController<PlayerException>.broadcast();
  final _androidAudioSessionIdController = StreamController<int?>.broadcast();

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration?> get durationStream => _durationController.stream;

  @override
  Stream<PlayerState> get playerStateStream => _playerStateController.stream;

  @override
  Stream<ProcessingState> get processingStateStream =>
      _processingStateController.stream;

  @override
  Stream<int?> get androidAudioSessionIdStream =>
      _androidAudioSessionIdController.stream;

  @override
  Stream<PlayerException> get errorStream => _errorController.stream;

  @override
  double get volume => 1.0;

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Duration get position => Duration.zero;

  @override
  bool get playing => false;

  @override
  ProcessingState get processingState => ProcessingState.idle;

  @override
  int? get androidAudioSessionId => null;

  void emitPosition(Duration value) => _positionController.add(value);

  void disposeStreams() {
    _positionController.close();
    _durationController.close();
    _playerStateController.close();
    _processingStateController.close();
    _androidAudioSessionIdController.close();
    _errorController.close();
  }
}

class _FakeAudioHandler extends Fake implements MusicAudioHandler {
  _FakeAudioHandler(this._audioPlayer);

  final AudioPlayer _audioPlayer;

  @override
  AudioPlayer get audioPlayer => _audioPlayer;

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
  }) {}

  @override
  void attachVoiceSearch({
    required Future<void> Function(String query) onVoiceSearch,
  }) {}

  @override
  void detachTransportControls() {}

  @override
  Future<void> seek(Duration position, [dynamic options]) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> close() async {}
}

class _MockMusicApi extends Fake implements MusicApi {
  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
  }) async {
    return PlayUrl(url: 'https://example.com/${song.hash}.mp3', hash: song.hash);
  }

  @override
  Future<List<LyricLine>> lyrics(Song song) async => const [];
}

Song _song() => Song(id: 'song_1', title: '歌曲', artist: '歌手', hash: 'hash_1');

List<LyricLine> _lyrics() => const [
  LyricLine(time: Duration.zero, text: '第一句'),
  LyricLine(time: Duration(seconds: 5), text: '第二句', translation: 'line 2'),
  LyricLine(time: Duration(seconds: 10), text: '第三句'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('shiyin_music/desktop_lyrics');

  late _FakeAudioPlayer fakeAudioPlayer;
  late _FakeAudioHandler handler;
  late PlayerController controller;
  late List<MethodCall> calls;

  /// 排空平台通道往返（show/loadLyrics/setPlaybackState 都是异步下发）。
  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  MethodCall lastCall(String method) {
    final matches = calls.where((c) => c.method == method).toList();
    expect(
      matches,
      isNotEmpty,
      reason: '未下发 $method 调用，实际=${calls.map((c) => c.method).toList()}',
    );
    return matches.last;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 伪装移动端形态 + Android 平台：走 AndroidLyricService 的通道分支。
    debugDesktopFormFactorOverride = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'checkPermission') return true;
      return null;
    });

    fakeAudioPlayer = _FakeAudioPlayer();
    handler = _FakeAudioHandler(fakeAudioPlayer);
    controller = PlayerController(_MockMusicApi(), handler);
    controller.currentSong = _song();
    controller.lyrics = _lyrics();
    controller.duration = const Duration(seconds: 30);
  });

  tearDown(() {
    controller.dispose();
    fakeAudioPlayer.disposeStreams();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    debugDesktopFormFactorOverride = null;
  });

  test('开启即常显：show + updateSettings + 整首歌词 loadLyrics + setPlaybackState', () async {
    await controller.setDesktopLyricsEnabled(true);
    await settle();

    expect(calls.map((c) => c.method), contains('show'));
    expect(calls.map((c) => c.method), contains('updateSettings'));
    final settingsArgs = lastCall('updateSettings').arguments as Map;
    expect(settingsArgs['themeMode'], 'system');
    expect(settingsArgs['doubleLine'], isTrue);

    // 整首歌词一次下发：三行 + 翻译字段（单行模式原生第二行用）。
    final args = lastCall('loadLyrics').arguments as Map;
    final lines = jsonDecode(args['lyrics'] as String) as List;
    expect(lines.length, 3);
    expect(lines[0]['text'], '第一句');
    expect(lines[1]['translation'], 'line 2');
    expect(lines[2]['timeMs'], 10000);

    expect(calls.map((c) => c.method), contains('setPlaybackState'));
  });

  test('同一份歌词重复同步不重复下发；偏移调整走 calibratePosition 重锚', () async {
    await controller.setDesktopLyricsEnabled(true);
    await settle();
    calls.clear();

    // 偏移调整会触发 _syncDesktopLyrics，但歌词没变（去重键命中），
    // 不得重复下发 loadLyrics；重锚改走 calibratePosition。
    await controller.setLyricOffset(const Duration(milliseconds: 500));
    await settle();

    expect(
      calls.map((c) => c.method),
      isNot(contains('loadLyrics')),
      reason: '歌词未变化，重复 loadLyrics 只会浪费 IPC',
    );
    expect(calls.map((c) => c.method), contains('calibratePosition'));
    final args = lastCall('calibratePosition').arguments as Map;
    expect(args['currentTimeMs'], 500);
  });

  test('切到无歌词的歌：下发空歌词表（原生不得残留上一首的句子）', () async {
    await controller.setDesktopLyricsEnabled(true);
    await settle();
    calls.clear();

    final silent = Song(
      id: 'song_2',
      title: '纯音乐',
      artist: '歌手',
      hash: 'hash_2',
    );
    controller.currentSong = silent;
    await controller.loadLyrics(silent);
    await settle();

    expect(calls.map((c) => c.method), contains('loadLyrics'));
    final args = lastCall('loadLyrics').arguments as Map;
    expect(args['lyrics'], '[]', reason: '空歌词也必须下发，清掉原生旧句');
  });

  test('进度条 seek 后下发 seekTo 重锚（含单曲偏移）', () async {
    await controller.setDesktopLyricsEnabled(true);
    await controller.setLyricOffset(const Duration(milliseconds: 500));
    await settle();
    calls.clear();

    await controller.seek(const Duration(seconds: 10));
    await settle();

    expect(calls.map((c) => c.method), contains('seekTo'));
    final args = lastCall('seekTo').arguments as Map;
    // lyricPosition = seek 目标 + 单曲偏移（与 loadLyrics 锚点同源）。
    expect(args['currentTimeMs'], 10500);
  });
}
