# 发版流程清单（每次发版按顺序过一遍）

> 换设备发版也以本文件为准。v2.0.0 起本项目仅发布 Android 端，桌面/Web 平台构建已移除。

## 1. 修改版本号（两处必须同步，缺一不可）

| 文件 | 改什么 |
|---|---|
| `pubspec.yaml` | `version: X.Y.Z+N` |
| `lib/config/app_config.dart` | `appVersion = 'X.Y.Z'`、`appVersionCode = 'N'` |

versionCode 规则：`X*1000000 + Y*1000 + Z`（如 2.5.1 → 2005001，minor/patch 须 < 1000）。
旧口径 `X*100 + Y*10 + Z` 在 minor 达两位数时会进位冲突（2.10.0 与 3.0.0 同为 300），已废弃。

## 2. 提交 release commit

```
release: vX.Y.Z

版本号更新为 X.Y.Z（versionCode N）：pubspec 与 app_config 双处同步
（正文可附本版要点）
```

参考历史：`git log --oneline --grep="release:"`。

## 3. 合并并推送 main

```bash
git checkout main
git merge --ff-only <修复分支>   # 有修复分支时
git push origin main
```

## 4. 打 tag 触发自动构建

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

- 推送 `v*` tag 触发「Build Android APK」流水线（约 10 分钟×3 变体：cargo-ndk 编译 Rust + impeller-arm64 / skia-arm64 / skia-arm32 三包）。
- 附件按固定顺序发布：`e-cells-music-vX.Y.Z-impeller-arm64.apk` 在前、`skia-arm64` 居中、`skia-arm32` 最后（顺序不能换，老版本只拿第一个）。
- 另有两份旧命名别名附件（`e-cells-music-arm64-v8a-vX.Y.Z.apk` / `e-cells-music-armeabi-v7a-vX.Y.Z.apk`，内容同 skia 变体），供易格 1.x 老客户端应用内更新命中。
- 签名来自仓库 Secrets（`RELEASE_KEYSTORE_BASE64` / `RELEASE_KEYSTORE_PASSWORD`），未配置时回退 debug 签名，不可覆盖安装正式版。
- 手动 `workflow_dispatch` 也可构建，但不会创建 Release。

## 5. 创建 GitHub Release（更新内容在这一步，Action 不写正文）

Action 只负责把 APK 挂到 Release；标题和正文（应用内更新弹窗展示的就是这份 body）用 gh CLI 手动创建：

```bash
gh release create vX.Y.Z --title "易格音乐 vX.Y.Z" --notes "<更新内容>"
```

先建 Release 也没关系，Action 之后只会往上面挂 APK，不会覆盖正文。
涉及签名变更等不兼容升级时，正文须显著写明「先卸载旧版再安装」。

## 6. 验证

```bash
gh run list --limit 3            # Android 流水线应为 success
gh release view vX.Y.Z           # assets 应含：三变体 apk + 两份别名 apk，均带 .sha256，
                                 # 顺序 impeller-arm64 → skia-arm64 → skia-arm32
```

## 7. 收尾（可选）

- 删除已合并的修复分支（本地与远端）。
- Action 日志若出现 actions 版本弃用警告（如 setup-java@v4），有空升级对应 action 版本。
