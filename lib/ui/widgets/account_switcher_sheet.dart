import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../models/music_models.dart';
import '../../services/music_api.dart';
import '../pages/login_page.dart';
import 'app_dialog.dart';
import 'toast.dart';

/// 弹出账号切换面板（「我的」页头像区入口）。
///
/// 面板自身负责切换/移除；「添加账号」以 true 关闭面板，由本函数接着
/// push 添加账号模式的登录页。
Future<void> showAccountSwitcherSheet(
  BuildContext context, {
  required AuthController auth,
  required MusicApi api,
}) async {
  final addAccount = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => AccountSwitcherSheet(auth: auth),
  );
  if (addAccount == true && context.mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LoginPage(auth: auth, api: api, isAddAccount: true),
      ),
    );
  }
}

/// 账号切换面板：本机已保存账号列表（点击切换、尾部移除）+ 添加账号。
///
/// 视觉与交互对齐登录页的账号选择面板（_AccountSelectionSheet）：同款
/// 圆角瓦片、头像、UID 副标题；弹层期间监听 auth 实时刷新列表与在途态。
class AccountSwitcherSheet extends StatefulWidget {
  const AccountSwitcherSheet({super.key, required this.auth});

  final AuthController auth;

  @override
  State<AccountSwitcherSheet> createState() => _AccountSwitcherSheetState();
}

class _AccountSwitcherSheetState extends State<AccountSwitcherSheet> {
  Future<void> _switch(SavedAccount account) async {
    if (widget.auth.isLoading) return;
    final ok = await widget.auth.switchAccount(account.userId);
    if (!mounted) return;
    // 切换发起即关面板：结果（成功/失败）用全局 Toast 反馈，
    // 弹层叠在半屏 sheet 上会被遮挡。
    Navigator.of(context).pop();
    if (ok) {
      Toast.success('已切换到 ${widget.auth.profile?.nickname ?? account.displayName}');
    } else if ((widget.auth.errorMessage ?? '').isNotEmpty) {
      // 例如目标账号 token 已过期：会话已切过去但资料拉取失败
      Toast.error(widget.auth.errorMessage!);
    }
  }

  Future<void> _remove(SavedAccount account) async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: '移除账号',
      message: '确定将「${account.displayName}」从本机移除吗？移除后需要重新登录才能使用。',
      confirmText: '移除',
    );
    if (!confirmed || !mounted) return;
    await widget.auth.removeAccount(account.userId);
    if (!mounted) return;
    // 最后一个账号被移除：已完整登出，清栈回登录页；否则面板保持打开，
    // 列表经 AnimatedBuilder 自动刷新。
    if (!widget.auth.isLoggedIn) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: AnimatedBuilder(
          animation: widget.auth,
          builder: (context, _) {
            final busy = widget.auth.isLoading;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '切换账号',
                  style: textTheme.titleLarge?.copyWith(
                    color: colorScheme.onSurface,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '点击账号快速切换，右侧按钮移除',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (busy) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    minHeight: 2.5,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
                const SizedBox(height: 14),
                Flexible(
                  // 切换/移除在途时禁点，防重复入队
                  child: IgnorePointer(
                    ignoring: busy,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: widget.auth.savedAccounts.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final accounts = widget.auth.savedAccounts;
                        if (index == accounts.length) {
                          return _AddAccountTile(
                            onTap: () => Navigator.of(context).pop(true),
                          );
                        }
                        final account = accounts[index];
                        return _SavedAccountTile(
                          account: account,
                          isCurrent:
                              account.userId == widget.auth.session?.userId,
                          onTap: () => _switch(account),
                          onRemove: () => _remove(account),
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SavedAccountTile extends StatelessWidget {
  const _SavedAccountTile({
    required this.account,
    required this.isCurrent,
    required this.onTap,
    required this.onRemove,
  });

  final SavedAccount account;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: isCurrent ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: colorScheme.primary.withValues(alpha: .12),
                backgroundImage: account.avatarUrl != null
                    ? ResizeImage(
                        NetworkImage(account.avatarUrl!),
                        width: 96,
                        height: 96,
                      )
                    : null,
                child: account.avatarUrl == null
                    ? Text(
                        account.displayName.substring(0, 1),
                        style: TextStyle(
                          color: colorScheme.primary,
                          fontWeight: FontWeight.w900,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            account.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.titleMedium?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (isCurrent) ...[
                          const SizedBox(width: 8),
                          Icon(
                            Icons.check_circle_rounded,
                            size: 18,
                            color: colorScheme.primary,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isCurrent ? '当前账号 · UID ${account.userId}' : 'UID ${account.userId}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isCurrent)
                IconButton(
                  tooltip: '移除账号',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  onPressed: onRemove,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddAccountTile extends StatelessWidget {
  const _AddAccountTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: .10),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.person_add_alt_1_rounded,
                  size: 22,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Text(
                '添加账号',
                style: textTheme.titleMedium?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
