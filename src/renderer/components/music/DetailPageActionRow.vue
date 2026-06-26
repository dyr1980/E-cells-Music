<script setup lang="ts">
import { computed } from 'vue';
import type { IconifyIcon } from '@iconify/types';
import { iconPlay, iconList } from '@/icons';
import Button from '@/components/ui/Button.vue';
import MvIcon from '@/components/ui/MvIcon.vue';
interface Action {
  icon: IconifyIcon;
  label: string;
  onTap: () => void | Promise<void>;
  emphasized?: boolean;
  tone?: 'default' | 'favorite';
  disabled?: boolean;
}

interface Props {
  playLabel?: string;
  playDisabled?: boolean;
  hidePlay?: boolean;
  hideBatch?: boolean;
  hideMv?: boolean;
  mvCount?: number;
  mvDisabled?: boolean;
  iconOnly?: boolean;
  onPlay?: () => void;
  secondaryActions?: Action[];
}

const props = withDefaults(defineProps<Props>(), {
  playLabel: '播放',
  playDisabled: false,
  hidePlay: false,
  hideBatch: false,
  hideMv: false,
  mvCount: 0,
  mvDisabled: false,
  iconOnly: false,
  secondaryActions: () => [],
});

const emit = defineEmits<{
  (e: 'play'): void;
  (e: 'batch'): void;
  (e: 'mv'): void;
}>();

const mvButtonLabel = computed(() => {
  return props.mvCount && props.mvCount > 0 ? `MV(${props.mvCount})` : 'MV';
});
</script>

<template>
  <!-- 竖屏图标模式 -->
  <div v-if="props.iconOnly" class="action-row-wrap flex flex-wrap items-center justify-start gap-1.5">
    <Button
      v-if="!props.hidePlay"
      variant="unstyled"
      size="none"
      :disabled="props.playDisabled"
      @click="emit('play')"
      class="p-2 rounded-lg hover:bg-black/5 dark:hover:bg-white/5 text-primary transition-colors"
      :class="{ 'opacity-45 pointer-events-none': props.playDisabled }"
    >
      <Icon :icon="iconPlay" width="20" height="20" />
    </Button>

    <Button
      v-if="!props.hideMv"
      variant="unstyled"
      size="none"
      :disabled="props.mvDisabled"
      @click="emit('mv')"
      class="p-2 rounded-lg hover:bg-black/5 dark:hover:bg-white/5 text-rose-400 transition-colors"
      :class="{ 'opacity-45 pointer-events-none': props.mvDisabled }"
    >
      <MvIcon class="w-5 h-5" />
    </Button>

    <Button
      v-for="action in secondaryActions"
      :key="action.label"
      variant="unstyled"
      size="none"
      @click="action.onTap"
      :disabled="action.disabled"
      class="p-2 rounded-lg hover:bg-black/5 dark:hover:bg-white/5 transition-colors"
      :class="[
        action.tone === 'favorite' ? 'text-red-400' : 'text-text-main/60',
        { 'opacity-45 pointer-events-none': action.disabled },
      ]"
    >
      <Icon :icon="action.icon" width="18" height="18" />
    </Button>

    <Button
      v-if="!props.hideBatch"
      variant="unstyled"
      size="none"
      @click="emit('batch')"
      class="p-2 rounded-lg hover:bg-black/5 dark:hover:bg-white/5 text-text-main/60 transition-colors"
    >
      <Icon :icon="iconList" width="18" height="18" />
    </Button>
  </div>

  <!-- 横屏带文字模式（默认） -->
  <div v-else class="action-row-wrap flex flex-wrap items-center justify-start gap-2.5">
    <Button v-if="!props.hidePlay" variant="unstyled" size="none" :disabled="props.playDisabled" @click="emit('play')" class="action-btn primary" :class="{ 'action-btn-disabled': props.playDisabled }">
      <Icon :icon="iconPlay" width="18" height="18" />
      <span>{{ playLabel }}</span>
    </Button>

    <Button
      v-if="!props.hideMv"
      variant="unstyled"
      size="none"
      :disabled="props.mvDisabled"
      @click="emit('mv')"
      class="action-btn secondary mv-btn"
      :class="{ 'action-btn-disabled': props.mvDisabled }"
    >
      <MvIcon class="w-4 h-4" />
      <span>{{ mvButtonLabel }}</span>
    </Button>

    <Button
      variant="unstyled"
      size="none"
      v-for="action in secondaryActions"
      :key="action.label"
      @click="action.onTap"
      :disabled="action.disabled"
      class="action-btn secondary"
      :class="[{ emphasized: action.emphasized }, action.tone === 'favorite' ? 'favorite' : '']"
    >
      <Icon :icon="action.icon" width="16" height="16" />
      <span>{{ action.label }}</span>
    </Button>

    <Button v-if="!props.hideBatch" variant="unstyled" size="none" @click="emit('batch')" class="action-btn secondary">
      <Icon :icon="iconList" width="16" height="16" />
      <span>批量</span>
    </Button>
  </div>
</template>

<style scoped>
@reference "@/style.css";

.action-btn {
  @apply flex items-center gap-1.5 px-4 h-10 rounded-full text-[13px] font-bold transition-all active:scale-95 select-none;
  background-color: var(--bg-info-card);
  color: var(--color-text-main);
}

.action-btn.primary {
  @apply bg-primary text-white hover:bg-primary-hover;
  box-shadow: 0 4px 12px color-mix(in srgb, var(--color-primary) 35%, transparent);
}

.action-btn.secondary.favorite {
  color: #f87171;
  background: color-mix(in srgb, #ef4444 8%, transparent);
}

.action-btn.secondary.favorite:hover {
  color: #ef4444;
  background: color-mix(in srgb, #ef4444 14%, transparent);
}

.action-btn.secondary.emphasized {
  color: #ef4444;
  background: color-mix(in srgb, #ef4444 12%, transparent);
}

.action-btn.secondary.emphasized:hover {
  color: #dc2626;
  background: color-mix(in srgb, #ef4444 18%, transparent);
}

.action-btn.secondary.mv-btn {
  color: #f87171;
  background: color-mix(in srgb, #ef4444 8%, transparent);
}

.action-btn.secondary.mv-btn:hover {
  color: #ef4444;
  background: color-mix(in srgb, #ef4444 14%, transparent);
}

.action-btn:hover {
  @apply brightness-95;
}

.dark .action-btn {
  background-color: rgba(255, 255, 255, 0.08);
}

.action-btn-disabled {
  opacity: 0.45;
  pointer-events: none;
}
</style>
