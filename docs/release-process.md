# 易格音乐 发版流程

> 适用仓库：`e-cells/E-cells-Music`
> CI 工作流：
> - `.github/workflows/build-android.yml`（打 `v*` tag 自动构建 Android 三变体 APK：impeller-arm64 / skia-arm64 / skia-arm32（老车机），另拷两份旧命名别名附件，按固定顺序附加到 Release）
> - `.github/workflows/publish-release.yml`（Android 构建全绿后自动把草稿 Release 转正）
>
> v2.0.0 起本项目仅发布 Android 端（桌面/Web 平台构建已移除）。

---

## 一、发版前检查

1. 确认所有要发布的修改已合并到 `main`
2. 确认 CI 在 `main` 上最近一次构建通过（如有）

## 二、签名配置（已就绪，无需每次操作）

本地和 CI 使用**同一个 release keystore**，签名一致，可互相覆盖安装。

| 项目 | 说明 |
|------|------|
| 密钥文件 | `android/app/release.keystore`（已 gitignore，**不可丢失**） |
| 本地配置 | `android/key.properties`（已 gitignore） |
| CI 配置 | GitHub Secrets：`RELEASE_KEYSTORE_BASE64` + `RELEASE_KEYSTORE_PASSWORD` |
| 别名 | `shiyin` |
| 构建逻辑 | `build.gradle.kts` 检测到 `key.properties` 时用 release 签名，否则回退 debug |

> ⚠️ **密钥密码丢失 = app 永远无法覆盖更新**，务必备份密码和 keystore 文件。
>
> 历史说明：v2.0.0 起为易格音乐 Flutter 版本线，签名与 1.x（Vue+GeckoView 版）
> 不同——1.x 老用户需卸载旧版后安装，Release 说明中必须写明。

## 三、升级版本号（三处必须同步）

| 文件 | 字段 | 示例 |
|------|------|------|
| `pubspec.yaml` | `version: x.y.z+code` | `2.0.1+2000001` |
| `lib/config/app_config.dart` | `appVersion` | `'2.0.1'` |
| `lib/config/app_config.dart` | `appVersionCode` | `'2000001'` |

> ⚠️ **必须在打 tag 之前完成版本号升级**，否则 CI 打出的包内部版本号是旧的，
> 会导致"关于"页显示错误版本、检查更新逻辑异常。

版本号规则：
- `versionName`：语义化版本 `major.minor.patch`
- `versionCode`：`major * 1000000 + minor * 1000 + patch`（如 `2.0.1` → `2000001`，pubspec 写作 `2.0.1+2000001`）
- 约束：`minor` 与 `patch` 须 `< 1000`（各占 3 位），否则高位进位破坏单调性

## 四、更新说明只写 GitHub Release body

v2.0.0 起不再维护应用内更新日志（原 `update.md` 已删除）：「关于」页不展示
历史版本列表，应用内更新弹窗展示的正是 GitHub Release 的 body。发版时把
用户可感知的变更写入 Release 笔记即可（模板见第六节）。

## 版本适用平台标记（历史机制，Android 单端下默认「全平台」）

Release notes 首部可写一行 blockquote 元信息（人可读 + 机器可读），客户端
`parseApplicablePlatforms` 据此过滤更新提示：

```markdown
> 适用平台：全平台
```

v2.0.0 起仅发布 Android 端，标记默认写「全平台」即可；词表与机制详见
`lib/models/app_version.dart`（`Windows` / `PC` 等词仍被解析，属于历史遗留）。

## 五、提交并推送

```bash
git add -A
git commit -m "release: v2.0.1"
git push origin main

# 推 v* tag：触发 Android 构建流水线
git tag v2.0.1
git push origin v2.0.1
```

## 六、创建 GitHub Release（草稿先行，全绿自动转正）

tag 推送后立刻用 `gh` CLI 创建**草稿** Release（注意 `--draft`）。草稿对公众
不可见、`/releases/latest` 也不返回——构建期间（约 10 分钟）Release 列表与
应用内检查更新看到的仍是上一版，**Release 一旦可见就必然附件齐全**：

```bash
# 1. 写 Release 笔记到临时文件（避免 shell 转义问题）

# 2. 创建草稿 Release（tag 推送后尽快执行：构建任务的上传步骤要求
#    Release 已存在）
gh release create v2.0.1 --draft --target main \
  --title "易格音乐 v2.0.1" --notes-file <notes-file>
```

Android 构建**成功后**，`publish-release.yml`（监听流水线的 workflow_run 事件）
自动 `gh release edit <tag> --draft=false` 把草稿转正——转正即对公众可见、
成为 latest，且此刻附件已全部就位。构建失败则 Release 停留草稿，按文末
「需要撤回已发布的版本」清理 tag 与草稿后重走流程；如需手动转正：
`gh release edit v2.0.1 -R e-cells/E-cells-Music --draft=false`。

> 为什么构建工作流用 `gh release upload` 而不是 softprops/action-gh-release：
> softprops 对已存在的草稿会在传完附件后自动 finalize（转正），把半成品
> Release 提前放出去；`gh release upload` 只传附件、永不改 Release 状态，
> 转正时机完全交给 publish-release.yml。

Release 笔记模板：

```markdown
> 适用平台：全平台

## 更新内容

### 🐛 Bug 修复

- **简要标题**：详细说明

### ✨ 新功能

- **简要标题**：详细说明

### 🔧 技术改进

- 说明

---

**完整变更**：https://github.com/e-cells/E-cells-Music/compare/v2.0.0...v2.0.1

## 📥 下载

每个产物均附带同名 `.sha256` 校验文件：应用内更新自动校验 SHA256 确保文件完整，手动下载可自行核对（Windows `certutil -hashfile <文件> SHA256` / Linux `sha256sum <文件>` / macOS `shasum -a 256 <文件>`）。点击文件名即可直接下载。

| 产物 | 说明 |
|------|------|
| [`e-cells-music-vX.Y.Z-impeller-arm64.apk`](https://github.com/e-cells/E-cells-Music/releases/download/vX.Y.Z/e-cells-music-vX.Y.Z-impeller-arm64.apk) | **Android 64 位 · Impeller 渲染（默认）**：绝大多数手机 / 车机选这个 |
| [`e-cells-music-vX.Y.Z-skia-arm64.apk`](https://github.com/e-cells/E-cells-Music/releases/download/vX.Y.Z/e-cells-music-vX.Y.Z-skia-arm64.apk) | **Android 64 位 · Skia 渲染**：Impeller 闪屏 / 冻屏 / 花屏的老 GPU 机型选这个 |
| [`e-cells-music-vX.Y.Z-skia-arm32.apk`](https://github.com/e-cells/E-cells-Music/releases/download/vX.Y.Z/e-cells-music-vX.Y.Z-skia-arm32.apk) | **Android 32 位 · Skia 渲染**：老车机 / 老 32 位设备专用 |
| [`e-cells-music-arm64-v8a-vX.Y.Z.apk`](https://github.com/e-cells/E-cells-Music/releases/download/vX.Y.Z/e-cells-music-arm64-v8a-vX.Y.Z.apk) | 64 位别名包（内容同 skia-arm64，供易格 1.x 老客户端应用内更新） |
| [`e-cells-music-armeabi-v7a-vX.Y.Z.apk`](https://github.com/e-cells/E-cells-Music/releases/download/vX.Y.Z/e-cells-music-armeabi-v7a-vX.Y.Z.apk) | 32 位别名包（内容同 skia-arm32，供易格 1.x 老客户端应用内更新） |
```

> 首行「适用平台」默认写「全平台」。

> ⚠️ **「## 📥 下载」区是格式契约**：
> - 标题必须保持 `## 📥 下载`（`##` 二级 + emoji + "下载"）——应用内更新弹窗
>   靠它截掉这一区，只向用户展示更新内容（`stripReleaseDownloadSection`）；
> - 该区约定为笔记**最后一节**；
> - 产物文件名必须带直链：写法固定为 `` [`<文件名>`](https://github.com/e-cells/E-cells-Music/releases/download/vX.Y.Z/<同名文件>) ``
>  （vX.Y.Z 换成当次 tag，链接与文本文件名保持同名），用户点表内文件名直达下载，
>   不用翻到页面底部附件区。文件名原文保留在链接文本里，`pickUpdateAssetUrl`
>   读的是 API 附件列表而不是正文，选包逻辑不受影响；
> - 产物文件名里的 `-{渲染器}-` 与 `-arm64`/`-arm32`（或别名 `-arm64-v8a`/
>   `-armeabi-v7a`）段是应用内更新选包依据（见 `AppVersionInfo` /
>   `pickUpdateAssetUrl`），重命名产物必须同步客户端。

> ⚠️ CI workflow 中 **不要** 开启 `generate_release_notes: true`，否则会覆盖手写笔记。
> 当前 workflow 配置为仅附加附件、不覆盖 body。

## 七、确认 CI 构建

```bash
gh run list -R e-cells/E-cells-Music --limit 4   # Android 构建 + Publish Release
gh run watch                                     # 实时跟踪（可选）
gh release view v2.0.1 -R e-cells/E-cells-Music  # 确认附件已附加、非草稿
```

Android 全绿后 `publish-release.yml` 会自动把草稿转正；确认 Release 页面
`isDraft=false` 且附件齐全即发版完成。若全绿但草稿未转正，用第六节的手动
转正命令兜底。

CI 完成后 Release 页面应包含（**顺序不能变**，impeller-arm64 在前——
老版本客户端只拿第一个 .apk 附件）：

- `e-cells-music-vX.Y.Z-impeller-arm64.apk` + `.sha256`
- `e-cells-music-vX.Y.Z-skia-arm64.apk` + `.sha256`
- `e-cells-music-vX.Y.Z-skia-arm32.apk` + `.sha256`
- `e-cells-music-arm64-v8a-vX.Y.Z.apk` + `.sha256`（旧命名别名，内容同 skia-arm64）
- `e-cells-music-armeabi-v7a-vX.Y.Z.apk` + `.sha256`（旧命名别名，内容同 skia-arm32）

> **sha256 sidecar**：CI 为每个附件生成同名 `.sha256` 文件（sha256sum
> 文本格式）。手动下载的用户可 `sha256sum -c` 自行核对。

> 附件命名是应用内更新的识别约定，**必须严格遵守**：
> Android 靠 `-{渲染器}-` 选渲染器包、`-arm64`/`-arm32` 选架构包
> （客户端按烘焙的 APP_ABI 匹配，32 位车机自动选 arm32 包；别名包
> `-arm64-v8a`/`-armeabi-v7a` 兼容易格 1.x 客户端的选包习惯）。

## 八、检查更新的多级容灾（403 规避）

应用内检查更新按以下顺序探测，任一级拿到确定结果（有更新 / 确定无更新）即返回
（对齐 handwrite-sim 的 updater 策略，规避 api.github.com 未鉴权 60 次/时/IP
的 403 风控）：

1. **GitHub REST API** `api.github.com/…/releases?per_page=30` 列表接口
   （信息最全；取最近 30 个 Release 做选版，空列表 = 无发布）
2. **Releases Atom 订阅源** `github.com/…/releases.atom` 取版本与正文 +
   **expanded_assets 资产页** `github.com/…/releases/expanded_assets/{tag}` 取附件直链
   （都在 github.com 域，不占 API 频次；最近约 10 条）
3. **/releases/latest 网页 302 重定向**探测最新 tag + expanded_assets 补直链
   （拿不到 notes 正文，由客户端 semver 比较兜底）

三级全部失败时：若见过 403/429 提示"检查频繁触发 GitHub 限流，请稍后再试"，
否则提示请求失败；自动检查静默，手动检查 Toast。

## 九、验证

- 在设备上安装对应变体 APK，确认「关于」页版本号正确且渲染引擎显示正确
- 点击「检查更新」，应提示"当前已是最新版本"
- 用旧版本 APK 点击「检查更新」，应弹出新版本更新弹窗
- 断网/限流：手动检查有 Toast 提示，启动自动检查不打扰

---

## 常见问题

### 检查更新提示"已是最新版本"但实际有新版本

- 确认 GitHub API 返回正确：`curl -H "User-Agent: ECellsMusic-App" https://api.github.com/repos/e-cells/E-cells-Music/releases/latest`
- 确认 `AppConfig.appVersion` 与当前安装版本一致
- 确认 Release 不是 draft / prerelease（`/releases/latest` 不返回这两类）
- 确认附件命名符合约定（找不到 `-arm64`/`-arm32` 及别名段时弹窗会退化为
  "打开发布页"）

### 检查更新提示限流 / 403

- API 被风控时会自动走 Atom 订阅源与网页重定向两级容灾（见第八节），
  全部失败才报错；一般等待即可恢复
- 手动复现：`curl -H "User-Agent: x" https://api.github.com/rate_limit` 查看余量

### 需要撤回已发布的版本

```bash
gh release delete v2.0.1 --yes        # 删除 Release（含附件）
git push origin :refs/tags/v2.0.1     # 删除远程 tag
git tag -d v2.0.1                     # 删除本地 tag
# 修复后重新走发版流程
```
