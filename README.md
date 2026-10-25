<div align="center">

<img src="lib/assets/logo.png" width="120" alt="易格音乐" />

# 易格音乐

**v2.0.0 · 懂你的每一首热爱**

为车机与手机打造的第三方音乐播放器

</div>

---

## 📖 简介

易格音乐是一个专注于**车载场景**的第三方音乐播放器，基于 Flutter 构建。它的一切改造都围绕一个朴素的最终目的——**让你能在车机里安心、顺畅地听歌**。

> **⚠️ v2.0.0 重要变化（老用户必读）**
>
> 自 v2.0.0 起，易格音乐基于开源项目 [时音 APP v3.0.13](https://github.com/bamboostrip/shiyin-music)（作者 bamboostrip）重新构建，安装包体积相比 1.x 版本大幅缩小。
>
> - **由于应用签名不同，安装 v2.0.0 前必须先卸载易格音乐 1.4.0 及更早版本**，卸载后数据无法保留，账号需重新登录；
> - 相对时音原版，本版本专门针对车机使用**重新设计了桌面歌词**，并**新增了语音点歌**（配合系统助手/车机语音说出歌名即可点播）；
> - **新增多账号登录与切换**：本机可保存多个账号（微信扫码 / 酷狗扫码 / 手机验证码均可登录），在「我的」页点击头像区即可一键切换、添加或移除账号，各账号的歌单、收藏与 VIP 状态完全隔离；
> - 除此之外未做其它修改——感谢原作者 bamboostrip 创建了这么好用的应用。

## 📥 下载

前往 [Releases](https://github.com/e-cells/E-cells-Music/releases) 下载最新版本：

| 产物 | 适用场景 |
|------|----------|
| `*-impeller-arm64.apk` | 主流 64 位设备 / 车机（默认渲染引擎） |
| `*-skia-arm64.apk` | 64 位设备，默认引擎渲染异常时改用 |
| `*-skia-arm32.apk` | 老旧 32 位车机 |

> 装错架构会提示无法安装，换对应 ABI 的包即可；旧命名别名包（`arm64-v8a` / `armeabi-v7a`）与上述包内容一致，供 1.x 老版本应用内更新使用。

## ✨ 主要功能

- 🎵 **音乐播放**：在线试听、歌单管理、每日推荐、排行榜、电台
- 👥 **多账号**：本机保存多个账号一键切换，歌单 / 收藏 / VIP 状态按账号隔离
- 📝 **歌词**：逐行/逐字歌词、桌面（悬浮窗）歌词——专为车机横屏优化
- 🗣️ **语音点歌**：系统助手/车机语音说出歌名即可点播
- ⬇️ **下载与缓存**：歌曲下载、播放缓存（LRU 自动清理）
- 🔊 **音效**：均衡器、重低音、环绕声、变速播放
- 🚗 **车载适配**：横屏布局、车机播放控制通知、熄屏续航优化

## 🛠️ 从源码构建

环境要求：Flutter SDK >= 3.11.5、Rust 工具链（`rustup` / `cargo`）、`cargo-ndk` 与对应 Android 目标（`rustup target add aarch64-linux-android`）、Android NDK。

Windows 下一键构建（自动完成依赖安装、代码分析与 APK 打包）：

```bash
build_apk.bat [impeller|skia] [release|debug] [arm64|arm32]
```

或手动构建：

```bash
git clone https://github.com/e-cells/E-cells-Music.git
cd E-cells-Music
flutter pub get
flutter build apk --release --target-platform android-arm64 \
  --flavor impeller --dart-define=APP_RENDERER=impeller --dart-define=APP_ABI=arm64
```

> v2.0.0 起本项目仅发布 Android 端。仓库已提交 `lib/src/rust/` 下的 FRB 生成代码，只有修改 `rust/` 接口时才需重新运行 `flutter_rust_bridge_codegen generate`。

## 🙏 致谢

- [时音 APP](https://github.com/bamboostrip/shiyin-music)（bamboostrip）——本项目 fork 的上游，一个出色的车机音乐播放器
- [kgka_Music_hl](https://github.com/umr-xiaomai/kgka_Music_hl)——时音的上游项目
- 所有为本项目提供依赖与灵感开源项目

## 👤 作者

**muye** · [github.com/e-cells/E-cells-Music](https://github.com/e-cells/E-cells-Music)

## 📄 声明

本项目仅供学习交流使用，请于下载后 24 小时内删除。音乐版权归属原作者及平台所有，请支持正版音乐。
