<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import Dialog from '@/components/ui/Dialog.vue';
import Avatar from '@/components/ui/Avatar.vue';
import Button from '@/components/ui/Button.vue';
import { useUserStore } from '@/stores/user';
import { useUserSwitchDialogStore } from '@/stores/userSwitchDialog';
import { usePlaylistStore } from '@/stores/playlist';
import { useToastStore } from '@/stores/toast';
import { iconUsers, iconPlus, iconX } from '@/icons';

const router = useRouter();
const userStore = useUserStore();
const dialogStore = useUserSwitchDialogStore();
const playlistStore = usePlaylistStore();
const toastStore = useToastStore();

const open = computed({
  get: () => dialogStore.switchDialogOpen,
  set: (v: boolean) => (v ? dialogStore.openSwitchDialog() : dialogStore.closeSwitchDialog()),
});

const activeUserId = computed(() => userStore.activeUserId);

// 按 savedAt 降序：最近使用的账号排前面
const sortedAccounts = computed(() =>
  [...userStore.accounts].sort((a, b) => b.savedAt - a.savedAt),
);

const handleSwitch = async (userid: number) => {
  if (userid === activeUserId.value) {
    dialogStore.closeSwitchDialog();
    return;
  }
  const ok = await userStore.switchToAccount(userid);
  if (!ok) {
    // 账号 token 已过期：提示并跳登录页（带 from 以便返回）。
    // 弹窗挂在 App.vue 顶层（page 过渡之外），关弹窗与切路由可并行，无需延时等待离场。
    toastStore.warning('该账号登录已过期，请重新登录');
    const current = router.currentRoute.value.fullPath;
    dialogStore.closeSwitchDialog();
    router.push({ path: '/login', query: { from: current } });
    return;
  }
  // 切换后刷新新用户的歌单缓存
  playlistStore.fetchUserPlaylists().catch(() => {});
  dialogStore.closeSwitchDialog();
  const switched = userStore.info;
  toastStore.success(`已切换到「${switched?.nickname || '当前账号'}」`);
};

// ── 退出二次确认 ──
const confirmOpen = ref(false);
const pendingRemoveId = ref<number | null>(null);
const pendingRemoveName = computed(
  () => userStore.accounts.find((a) => a.userid === pendingRemoveId.value)?.nickname || '该账号',
);

const handleRemove = (userid: number, e: Event) => {
  e.stopPropagation();
  pendingRemoveId.value = userid;
  confirmOpen.value = true;
};

const confirmRemove = () => {
  if (pendingRemoveId.value == null) return;
  userStore.logoutAccount(pendingRemoveId.value);
  confirmOpen.value = false;
  pendingRemoveId.value = null;
  // 退出最后一个账号 → 已完全登出，关窗回首页
  if (!userStore.isLoggedIn) {
    dialogStore.closeSwitchDialog();
    router.push('/main/home');
  }
};

const handleAddAccount = () => {
  // 弹窗挂在 App.vue 顶层（page 过渡之外），关弹窗与切路由可并行。
  // 用 from 指向当前路由，登录成功/退出后能回到原页面。
  const current = router.currentRoute.value.fullPath;
  dialogStore.closeSwitchDialog();
  router.push({ path: '/login', query: { from: current } });
};
</script>

<template>
  <Dialog
    v-model:open="open"
    title="用户切换"
    :show-close="true"
    content-class="user-switch-dialog"
  >
    <!-- 账号列表 -->
    <div v-if="sortedAccounts.length" class="account-list">
      <div
        v-for="acc in sortedAccounts"
        :key="acc.userid"
        role="button"
        tabindex="0"
        :class="['account-row', { 'is-active': acc.userid === activeUserId }]"
        @click="handleSwitch(acc.userid)"
        @keydown.enter.prevent="handleSwitch(acc.userid)"
        @keydown.space.prevent="handleSwitch(acc.userid)"
      >
        <div class="account-avatar">
          <Avatar :src="acc.pic" class="w-full h-full rounded-full" />
        </div>
        <div class="account-meta">
          <span class="account-name">{{ acc.nickname || '未命名' }}</span>
          <span class="account-sub">
            {{ acc.userid === activeUserId ? '当前账号' : `Lv.${acc.p_grade || 0}` }}
          </span>
        </div>
        <span
          v-if="acc.userid === activeUserId"
          class="active-dot"
          aria-hidden="true"
        ></span>
        <button
          type="button"
          class="remove-btn"
          aria-label="退出该账号"
          @click="handleRemove(acc.userid, $event)"
        >
          <Icon :icon="iconX" width="14" height="14" />
        </button>
      </div>
    </div>

    <!-- 空状态 -->
    <div v-else class="empty-state">
      <Icon :icon="iconUsers" width="36" height="36" class="opacity-30" />
      <p class="empty-text">暂无已登录账号</p>
    </div>

    <!-- 添加账号 -->
    <button type="button" class="add-account-btn" @click="handleAddAccount">
      <span class="add-icon">
        <Icon :icon="iconPlus" width="16" height="16" />
      </span>
      <span>添加账号</span>
    </button>

    <!-- 退出二次确认 -->
    <Dialog
      v-model:open="confirmOpen"
      title="退出账号"
      :description="`确定要退出「${pendingRemoveName}」吗？退出后需重新登录。`"
    >
      <template #footer>
        <Button variant="outline" size="sm" @click="confirmOpen = false">取消</Button>
        <Button variant="danger" size="sm" @click="confirmRemove">确认退出</Button>
      </template>
    </Dialog>
  </Dialog>
</template>

<style scoped>
@reference "@/style.css";

.account-list {
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.account-row {
  display: flex;
  align-items: center;
  gap: 12px;
  width: 100%;
  padding: 9px 10px;
  border-radius: 14px;
  border: 1px solid transparent;
  background: transparent;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: background 0.18s ease, border-color 0.18s ease, transform 0.12s ease;
  text-align: left;
}

.account-row:hover {
  background: color-mix(in srgb, var(--color-text-main) 5%, transparent);
}

.account-row:active {
  transform: scale(0.985);
}

.account-row.is-active {
  background: color-mix(in srgb, var(--color-primary) 12%, transparent);
  border-color: color-mix(in srgb, var(--color-primary) 28%, transparent);
}

.account-avatar {
  width: 38px;
  height: 38px;
  flex-shrink: 0;
  border-radius: 50%;
  overflow: hidden;
  background: color-mix(in srgb, var(--color-primary) 10%, transparent);
}

.account-meta {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.account-name {
  font-size: 14px;
  font-weight: 700;
  color: var(--color-text-main);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.account-sub {
  font-size: 11px;
  font-weight: 600;
  color: color-mix(in srgb, var(--color-text-main) 50%, transparent);
}

.active-dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--color-primary);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--color-primary) 25%, transparent);
  flex-shrink: 0;
}

.remove-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 26px;
  height: 26px;
  flex-shrink: 0;
  border-radius: 50%;
  border: none;
  background: transparent;
  color: color-mix(in srgb, var(--color-text-main) 45%, transparent);
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: background 0.15s ease, color 0.15s ease, transform 0.12s ease;
}

.remove-btn:hover {
  background: color-mix(in srgb, #ef4444 15%, transparent);
  color: #ef4444;
}

.remove-btn:active {
  transform: scale(0.9);
}

/* 空状态 */
.empty-state {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 8px;
  padding: 28px 0 22px;
  color: var(--color-text-main);
}

.empty-text {
  font-size: 13px;
  font-weight: 600;
  color: var(--color-text-secondary);
}

/* 添加账号 */
.add-account-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  width: 100%;
  margin-top: 10px;
  padding: 11px;
  border-radius: 14px;
  border: 1px dashed color-mix(in srgb, var(--color-border-light) 80%, transparent);
  background: transparent;
  color: var(--color-primary);
  font-size: 14px;
  font-weight: 700;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: background 0.18s ease, border-color 0.18s ease, transform 0.12s ease;
}

.add-account-btn:hover {
  background: color-mix(in srgb, var(--color-primary) 8%, transparent);
  border-color: color-mix(in srgb, var(--color-primary) 50%, transparent);
}

.add-account-btn:active {
  transform: scale(0.985);
}

.add-icon {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 22px;
  height: 22px;
  border-radius: 50%;
  background: color-mix(in srgb, var(--color-primary) 15%, transparent);
}
</style>
