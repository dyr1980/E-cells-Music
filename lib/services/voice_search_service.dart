import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 语音点歌（系统助手/车机语音）通道客户端。
///
/// 冷启动链路：助手以 `MEDIA_PLAY_FROM_SEARCH` 拉起 MainActivity →
/// 原生提取 query（SearchManager.QUERY → "query" extra → artist+title）→
/// Flutter 未就绪时暂存在原生侧 → [init] 挂好回调并调用 `ready` →
/// 原生把暂存的 query 冲刷过来（`onVoiceSearch`）。
///
/// 热路径（应用在运行、媒体会话活跃）不经本类：MediaSession
/// `onPlayFromSearch` 由 audio_service 转发给 MusicAudioHandler.playFromSearch。
/// 两条路径最终都汇聚到 PlayerController.voiceSearchPlay。
class VoiceSearchService {
  VoiceSearchService._();

  static final VoiceSearchService instance = VoiceSearchService._();
  static const MethodChannel _channel = MethodChannel('shiyin_music/voice_search');

  bool _initialized = false;

  /// 挂接 query 回调并通知原生" Dart 已就绪"（触发暂存 query 冲刷）。
  /// 幂等：重复调用只更新回调。
  void init({required void Function(String query) onQuery}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onVoiceSearch') {
        final args = call.arguments;
        if (args is Map) {
          final query = args['query'];
          if (query is String && query.trim().isNotEmpty) {
            onQuery(query.trim());
          }
        }
      }
    });
    if (!_initialized) {
      _initialized = true;
      _channel.invokeMethod<void>('ready').catchError((Object e) {
        // 原生端未注册（非 Android 平台/引擎未就绪）时静默忽略。
        if (e is MissingPluginException) return null;
        if (kDebugMode) {
          debugPrint('[时音][语音点歌] ready 调用失败: $e');
        }
        return null;
      });
    }
  }
}
