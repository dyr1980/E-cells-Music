// player_controller.voice_search.dart —— PlayerController 的职责分片：
// 语音点歌（系统助手/车机语音）。成员声明与字段见 player_controller.dart。
//
// 两条入口汇聚到 [voiceSearchPlay]：
// - 冷启动：MainActivity 收到 MEDIA_PLAY_FROM_SEARCH → 暂存/冲刷 query
//   → VoiceSearchService 回调（main.dart 接线）。
// - 热路径：MediaSession onPlayFromSearch → audio_service →
//   MusicAudioHandler.playFromSearch → attachVoiceSearch 闭包。
//
// 播放策略逐行移植自易格音乐 player.ts voiceSearchPlay：
// 语音控制指令（下一首/上一首/暂停/继续）子串拦截，其余视为搜索词；
// voiceSearchMode = 'all'（默认，结果整队替换）/ 'first'（仅播首曲，
// 插到当前曲目之后，不动原队列）。
part of 'player_controller.dart';

mixin _PlayerVoiceSearch on _PlayerControllerBase {
  /// 语音点歌主入口：拦截控制指令，否则搜索并按模式播放。
  Future<void> voiceSearchPlay(String query) async {
    try {
      if (query.trim().isEmpty) return;
      final text = query.trim().toLowerCase();

      // 1. 拦截常见的语音控制指令（子串匹配，关键词表与易格逐项一致）。
      const nextKeywords = [
        '下一首歌曲', '下一首歌', '换下一首', '切下一首', '再来一首', '再来一曲',
        '换一首歌', '跳一首', '跳一曲', '切一首', '下一首', '下一曲', '下一支',
        '换一首', '换歌', '切歌', '跳过', '下首', '下首歌', '后一首', '下一集',
        '往后切', 'next track', 'next song', 'skip', 'next',
      ];
      const prevKeywords = [
        '上一首歌曲', '回上一首', '回上一曲', '切上一首', '回退一首', '上一首歌',
        '上一首', '上一曲', '上一支', '上一曲目', '前一首歌', '上一集', '退一首',
        '退一曲', '倒一首', '往前切', '上首', '上首歌', '前一首',
        'previous track', 'prev track', 'previous', 'prev',
      ];
      const pauseKeywords = ['暂停播放', '暂停', '停', '别放了', '停止播放', 'pause', 'stop'];
      const playKeywords = ['继续播放', '开始播放', '继续', '播放', '开始', 'play', 'resume'];

      if (nextKeywords.any(text.contains)) {
        await next();
        return;
      }
      if (prevKeywords.any(text.contains)) {
        await previous();
        return;
      }
      if (pauseKeywords.any(text.contains)) {
        if (isPlaying) await togglePlay();
        return;
      }
      if (playKeywords.any(text.contains)) {
        if (!isPlaying) await togglePlay();
        return;
      }

      // 2. 非控制指令：搜索播放（与易格同规模，一次取 100 条）。
      final songs = await _api.searchSongs(query.trim(), page: 1, pageSize: 100);
      if (songs.isEmpty) {
        debugPrint('[易格][语音点歌] 无搜索结果: "$query"');
        return;
      }

      if (voiceSearchMode == 'first') {
        // 仅播首曲：不替换当前队列，插到当前曲目之后，播完继续原列表
        // （易格同语义；上游无队列命名 API，易格的"语音搜索: query"
        // 队列标题无对应物，舍弃）。
        final newQueue = List<Song>.of(queue);
        // currentIndex 源自 queue（≤length-1），+1 后必在 [0, length] 内。
        final insertAt = currentIndex < 0 ? 0 : currentIndex + 1;
        newQueue.insert(insertAt, songs.first);
        await playSong(songs.first, queue: newQueue);
      } else {
        // 全部结果（默认）：搜索结果整体作为播放队列，从第一首开始。
        await playSong(songs.first, queue: songs);
      }
      debugPrint(
        '[易格][语音点歌] 已播放: "${songs.first.title}" '
        '(mode=$voiceSearchMode, results=${songs.length})',
      );
    } catch (e) {
      debugPrint('[易格][语音点歌] 失败: $e');
    }
  }
}
