<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import Popover from '@/components/ui/Popover.vue';
import { useUserSwitchDialogStore } from '@/stores/userSwitchDialog';
import { iconUser, iconUsers } from '@/icons';

/**
 * "头像与昵称"入口的下拉菜单：个人资料 / 用户切换。
 * 用 Popover(manual 模式) 包裹入口卡片作为触发器，点击菜单项后自动收起。
 * 横竖屏共用，通过 side prop 控制弹出方向。
 */
const props = defineProps<{
  /** 弹出方向：横屏卡片在底部用 top，竖屏卡片在顶部用 bottom */
  side?: 'top' | 'bottom';
}>();

const router = useRouter();
const dialogStore = useUserSwitchDialogStore();

const open = ref(false);
const rootRef = ref<HTMLElement | null>(null);

const toggle = () => {
  open.value = !open.value;
};
const close = () => {
  open.value = false;
};

const goProfile = () => {
  close();
  router.push('/main/profile');
};
const openSwitch = () => {
  close();
  dialogStore.openSwitchDialog();
};

// manual 模式下自行处理点击外部关闭（含 portal 渲染出的气泡内容）
const handleDocumentMousedown = (e: MouseEvent) => {
  if (!open.value) return;
  const target = e.target as Element | null;
  if (!target) return;
  // 点击在触发器或气泡内容内 → 不关闭
  if (rootRef.value?.contains(target)) return;
  if (target.closest && target.closest('.echo-popover-content')) return;
  close();
};

onMounted(() => document.addEventListener('mousedown', handleDocumentMousedown, true));
onUnmounted(() => document.removeEventListener('mousedown', handleDocumentMousedown, true));
</script>

<template>
  <div ref="rootRef" class="user-entry-root">
    <Popover
      :open="open"
      trigger="manual"
      :side="side || 'top'"
      align="start"
      :side-offset="8"
      :show-arrow="true"
      content-class="user-entry-menu"
      :block="true"
    >
      <template #trigger>
        <span class="user-entry-trigger" @click="toggle">
          <slot />
        </span>
      </template>

      <div class="menu-list">
        <button type="button" class="menu-item" @click="goProfile">
          <Icon :icon="iconUser" width="16" height="16" />
          <span>个人资料</span>
        </button>
        <button type="button" class="menu-item" @click="openSwitch">
          <Icon :icon="iconUsers" width="16" height="16" />
          <span>用户切换</span>
        </button>
      </div>
    </Popover>
  </div>
</template>

<style scoped>
@reference "@/style.css";

/* 根容器：撑满父级，使原入口卡片宽度不变 */
.user-entry-root {
  display: flex;
  width: 100%;
  min-width: 0;
}

/* 触发器：撑满父容器，透传给原入口卡片 */
.user-entry-trigger {
  display: flex;
  width: 100%;
  min-width: 0;
  cursor: pointer;
}

.menu-list {
  display: flex;
  flex-direction: column;
  gap: 2px;
  min-width: 148px;
  padding: 4px;
}

.menu-item {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 9px 11px;
  border-radius: 11px;
  border: none;
  background: transparent;
  color: var(--color-text-main);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  -webkit-tap-highlight-color: transparent;
  transition: background 0.15s ease, color 0.15s ease, transform 0.1s ease;
}

.menu-item:hover {
  background: color-mix(in srgb, var(--color-primary) 12%, transparent);
  color: var(--color-primary);
}

.menu-item:active {
  transform: scale(0.97);
}
</style>
