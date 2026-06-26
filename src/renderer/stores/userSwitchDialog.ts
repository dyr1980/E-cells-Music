import { defineStore } from 'pinia';

/**
 * 用户切换弹窗的开关状态（瞬态 UI，不持久化）。
 * UserSwitchDialog 全局唯一挂在 App.vue 顶层（RouterView 的 page 过渡之外），由该 store 控制显隐，
 * 可从侧边栏、竖屏"我的"页、个人资料页等多处触发。
 */
export const useUserSwitchDialogStore = defineStore('userSwitchDialog', {
  state: () => ({
    switchDialogOpen: false,
  }),
  actions: {
    openSwitchDialog() {
      this.switchDialogOpen = true;
    },
    closeSwitchDialog() {
      this.switchDialogOpen = false;
    },
  },
});
