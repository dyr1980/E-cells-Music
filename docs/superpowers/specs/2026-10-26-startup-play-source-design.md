# 开机播放内容设置设计

## 概述

「设置-播放-开机自启播放」开启时新增子选项「开机播放内容」，允许用户选择打开应用自动播放的内容：**继续播放**（恢复上次队列，默认，保持既有行为）或**每日推荐**（播推荐歌单并整体替换队列）。

此前两条路径是隐式的：有上次播放状态就继续上次队列，否则回退播每日推荐。本次改为用户可显式指定偏好，每日推荐不可用时仍回退继续播放。

## 需求

1. **子选项仅在开关开启时展示**（仿「桌面歌词开关联动歌词设置」模式），关闭时设置分节布局与现状一致
2. **默认值 `resume`**：不改动现有用户的行为
3. **每日推荐为空时回退继续播放**：未登录/接口失败/无缓存时开关不应"静默失效"
4. **不承诺进度续播与"今日"**：播放状态只持久化队列/当前歌/播放模式，不存进度；首页磁盘缓存 adopt 不判 `isStale`，缓存的推荐歌单可能过期

## 技术方案

### 1. 持久化

与同分节「语音搜歌模式」完全同构：

- **SharedPreferences key**: `settings.startup_play_source`
- **取值**: `'resume'`（默认）/ `'daily'`，非法持久化值与非法 setter 入参均回落 `'resume'`
- **字段**: `PlayerController.startupPlaySource`；setter `setStartupPlaySource`（落盘 + `notifyListeners`，同值幂等）；恢复在 `_restoreSettings()`

### 2. UI（`playback_settings_section.dart`）

- 开关后条件插入 `SettingsTile`（`if (player.autoPlayOnStartupEnabled) ...[]`），图标色与父开关一致（`0xFF00897B`）表从属
- 点击弹 `SimpleDialog`（仿语音搜歌弹窗）：两个选项「继续播放」「每日推荐」，subtitle 如实描述回退行为
- 不加形态/平台守卫：父开关全形态可见，本设置无平台依赖

### 3. 播放分支（`home_page.dart` `_checkAndAutoPlay`）

守卫（`!hasRestored && songs.isEmpty → return`，不消费机会）不变，仅改播放分支：

```
if (songs.isNotEmpty && (preferDaily || !hasRestored)) playSong(songs.first, queue: songs)
else resumePlayback()
```

真值表（8 组合已验证完备）：

| preferDaily | hasRestored | songs | 结果 |
|---|---|---|---|
| F | T | 任意 | resume（现状） |
| F | F | 非空 | daily 兜底（现状） |
| F | F | 空 | 守卫拦截，等数据（现状） |
| T | T | 非空 | **daily（新行为）** |
| T | T | 空 | resume（回退） |
| T | F | 非空 | **daily（新行为）** |
| T | F | 空 | 守卫拦截，等数据 |

`else` 分支必然有恢复队列（`preferDaily && songs.isEmpty` 时守卫保证 `hasRestored == true`），无空队列风险。

## 关键决策记录

1. **`startupPlaySource` 在消费时刻（`Future.delayed` 闭包内）读取**，而非守卫时刻：`_restoreSettings` 是构造函数 unawaited 发起的异步恢复，守卫时刻可能尚未落地；消费时刻（首帧后 / Windows 再 +300ms）prefs 必然恢复完成。竞态后果不对称——读输 `autoPlayOnStartupEnabled` 是"少播"（现状已接受），读输 `startupPlaySource` 是"播错内容"。`hasRestored` 保持守卫时刻捕获（参与"不消费机会"判断）。
2. **接受过期缓存播出的旧推荐歌单**：与现状 `!hasRestored` 分支暴露一致，非新引入退化；静默刷新后 UI 列表会更新，仅已入队的歌不跟随。想严格"当日"需把 `isStale` 透传进 `onDataArrived`（改基类签名，波及推荐/排行/电台三页面），收益不成比例。
3. **preferDaily 播放后 `_savePlaybackState` 会把推荐队列持久化为"上次队列"**：下次「继续播放」恢复的就是它。这是自然语义（它就是"上次的队列"），非 bug。

## 测试

- `test/controllers/player_startup_play_source_setting_test.dart`：默认值 / 启动恢复 / 落盘+通知+幂等+非法入参回落 / 非法持久化值回落
- `test/ui/pages/home_auto_play_daily_test.dart`：开启自启播放 + 偏好每日推荐 + 有恢复状态 → 播推荐首曲并替换队列、不调 `resumePlayback`（单测例文件：`_hasAutoPlayed` 是 static，同文件跨测例不重置）
