import { defineStore } from 'pinia';
import {
  claimDayVip,
  getServerNow,
  getUserDetail,
  getUserFollow,
  getUserVipDetail,
  getVipMonthRecord,
  upgradeDayVip,
} from '@/api/user';
import type { User, UserExtendsInfo } from '@/models/user';
import type { Account, MinimalUserInfo } from '@/models/account';
import { mapUser } from '@/utils/mappers';
import logger from '@/utils/logger';
import { useToastStore } from '@/stores/toast';

export type UserInfo = User;

interface ApiPayload {
  status?: number;
  data?: unknown;
  [key: string]: unknown;
}

const asApiPayload = (value: unknown): ApiPayload | null => {
  if (!value || typeof value !== 'object') return null;
  return value as ApiPayload;
};

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
};

const mergeExtendsInfo = (
  ...sources: Array<UserExtendsInfo | undefined>
): UserExtendsInfo | undefined => {
  const merged = sources.reduce<UserExtendsInfo>((acc, source) => {
    if (!source) return acc;
    return {
      ...acc,
      ...source,
      detail: isRecord(source.detail)
        ? {
            ...(isRecord(acc.detail) ? acc.detail : {}),
            ...source.detail,
          }
        : acc.detail,
      vip: isRecord(source.vip)
        ? {
            ...(isRecord(acc.vip) ? acc.vip : {}),
            ...source.vip,
          }
        : acc.vip,
    };
  }, {});

  return Object.keys(merged).length > 0 ? merged : undefined;
};

const normalizeUserInfo = (info: UserInfo): UserInfo => {
  const next = { ...info };

  if (
    (typeof next.userid !== 'number' || next.userid <= 0) &&
    typeof next.userId === 'number' &&
    next.userId > 0
  ) {
    next.userid = next.userId;
  }
  if (
    (typeof next.userId !== 'number' || next.userId <= 0) &&
    typeof next.userid === 'number' &&
    next.userid > 0
  ) {
    next.userId = next.userid;
  }

  return next;
};

const buildPatchedUserInfo = (current: UserInfo | null, patch: Partial<UserInfo>): UserInfo => {
  return normalizeUserInfo({
    ...(current ?? { userid: 0, token: '' }),
    ...patch,
  });
};

/**
 * 由登录/刷新响应数据构建完整 UserInfo。
 * @param base base=null 表示「登录全新账号」——绝不继承旧 info，缺失字段留空
 *             （由后续 fetchUserInfo 补全）；base=UserInfo 表示「刷新当前账号」——
 *             以当前 info 为底打补丁（fetchUserInfo 语义）。这是区分多账号串号的关键。
 */
const buildUserInfoFromLoginData = (
  data: Record<string, unknown>,
  base: UserInfo | null,
): UserInfo => {
  const mapped = mapUser(data);

  const detailPayload = isRecord(data.detail)
    ? data.detail
    : isRecord(data.extendsInfo) &&
        isRecord((data.extendsInfo as Record<string, unknown>).detail)
      ? ((data.extendsInfo as Record<string, unknown>).detail as Record<string, unknown>)
      : isRecord(data)
        ? data
        : undefined;

  const vipPayload = isRecord(data.vip)
    ? data.vip
    : isRecord(data.extendsInfo) && isRecord((data.extendsInfo as Record<string, unknown>).vip)
      ? ((data.extendsInfo as Record<string, unknown>).vip as Record<string, unknown>)
      : undefined;

  // base=null 时不继承旧账号的 extendsInfo，仅合并本次响应内的来源
  const mergedExtends = mergeExtendsInfo(
    base?.extendsInfo,
    mapped.extendsInfo,
    detailPayload ? { detail: detailPayload } : undefined,
    vipPayload ? { vip: vipPayload } : undefined,
  );

  return buildPatchedUserInfo(base, {
    ...mapped,
    ...(mergedExtends
      ? {
          extends: mergedExtends,
          extendsInfo: mergedExtends,
          ...(mergedExtends.detail ? { detail: mergedExtends.detail } : {}),
          ...(mergedExtends.vip ? { vip: mergedExtends.vip } : {}),
        }
      : {}),
  });
};

// ── 多账号（用户切换）辅助函数 ──

/** 从当前 UserInfo 抽取账号快照（仅保留切换所需最少字段） */
const accountFromInfo = (info: UserInfo): Account => ({
  userid: info.userid,
  token: info.token,
  nickname: info.nickname,
  pic: info.pic,
  p_grade: info.p_grade,
  t1: info.t1,
  expires: info.expires,
  savedAt: Date.now(),
});

/** 由账号快照反向构造最小可用 UserInfo（供 setUserInfo 切换身份） */
const minimalInfoFromAccount = (acc: Account): MinimalUserInfo => ({
  userid: acc.userid,
  userId: acc.userid,
  token: acc.token,
  nickname: acc.nickname,
  pic: acc.pic,
  p_grade: acc.p_grade,
  t1: acc.t1,
  expires: acc.expires,
});

/** 判断账号 token 是否已过期（expires 缺失视为永久有效） */
const isAccountExpired = (acc: Account): boolean => {
  if (!acc.expires) return false;
  return acc.expires <= Date.now();
};

export const useUserStore = defineStore('user', {
  state: () => ({
    info: null as UserInfo | null,
    isLoggedIn: false,
    hasFetchedUserInfo: false,
    isFetchingUserInfo: false,
    isTvipClaimedToday: false,
    isSvipClaimedToday: false,
    isAutoClaimingVip: false,
    followedArtistIds: new Set<string>(),
    hasFetchedFollowedArtists: false,
    // ── 多账号（用户切换）状态 ──
    // 已登录账号列表（含 token 等凭证，需持久化）
    accounts: [] as Account[],
    // 当前活跃账号的 userid，与 info.userid 同步
    activeUserId: null as number | null,
  }),
  actions: {
    setUserInfo(info: UserInfo) {
      const nextInfo = normalizeUserInfo(info);
      this.$patch((state) => {
        state.info = nextInfo;
        state.isLoggedIn = !!nextInfo.token;
        if (!nextInfo.token) {
          state.hasFetchedUserInfo = false;
        }
      });
    },
    handleLoginSuccess(data: Record<string, unknown>) {
      // 语义：刷新当前账号（fetchUserInfo / VIP 领取后刷新）。以当前 info 为 base 打补丁。
      this.hasFetchedUserInfo = false;
      this.setUserInfo(buildUserInfoFromLoginData(data, this.info));
      this.saveCurrentAccount();
      // 集中收敛：任何登录/添加账号成功后，统一触发今日会员自动领取（受 autoReceiveVip 控制）
      void this.triggerAutoReceiveVipIfNeeded();
    },
    /**
     * 登录全新账号（Login.vue 三种登录方式统一入口）。
     * 与 handleLoginSuccess 的关键区别：base=null 干净构建，绝不继承旧账号的
     * userid/token/t1/expires/pic/p_grade/nickname，从根上杜绝多账号串号/覆盖。
     * 解析失败兜底：若登录响应解析不出 userid/token，info.token 为空 →
     * setUserInfo 置 isLoggedIn=false、saveCurrentAccount 直接 return，不串号不覆盖。
     */
    loginAsNewAccount(data: Record<string, unknown>) {
      // 当前已登录 → 先落盘当前账号（同 userid 幂等，异 userid 保全最新数据）
      if (this.isLoggedIn && this.info?.userid && this.info?.token) {
        this.saveCurrentAccount();
      }
      // base=null 干净构建（关键：杜绝继承旧 info）；显式置 false 确保随后补全真正执行
      this.hasFetchedUserInfo = false;
      this.setUserInfo(buildUserInfoFromLoginData(data, null));
      // 写入账号列表
      this.saveCurrentAccount();
      // 参照 switchToAccount：无条件补全新账号完整信息 + 按设置自动领取今日会员
      void (async () => {
        try {
          await this.fetchUserInfoOnce();
        } catch (e) {
          logger.warn('UserStore', 'loginAsNewAccount: fetchUserInfo failed', e);
        }
        try {
          const { useSettingStore } = await import('@/stores/setting');
          if (useSettingStore().autoReceiveVip) {
            await this.autoReceiveVipIfNeeded();
          }
        } catch (e) {
          logger.warn('UserStore', 'loginAsNewAccount: autoReceiveVip failed', e);
        }
      })();
    },
    async fetchUserInfo() {
      if (!this.isLoggedIn) return;
      try {
        const [detailRes, vipRes] = await Promise.all([getUserDetail(), getUserVipDetail()]);
        const detailPayload = asApiPayload(detailRes);
        const vipPayload = asApiPayload(vipRes);

        if (detailPayload?.status === 1) {
          logger.info('UserStore', 'User detail fetched');
          const payload =
            detailPayload.data && typeof detailPayload.data === 'object'
              ? (detailPayload.data as Record<string, unknown>)
              : detailPayload;
          this.handleLoginSuccess(payload);
        }

        if (vipPayload?.status === 1 && this.info) {
          logger.info('UserStore', 'VIP detail fetched');
          const vipData =
            vipPayload.data && typeof vipPayload.data === 'object'
              ? (vipPayload.data as Record<string, unknown>)
              : undefined;
          const mergedExtends = mergeExtendsInfo(
            this.info.extendsInfo,
            vipData ? { vip: vipData } : undefined,
          );

          this.setUserInfo(
            buildPatchedUserInfo(this.info, {
              ...(vipData ? { vip: vipData } : {}),
              ...(mergedExtends ? { extends: mergedExtends, extendsInfo: mergedExtends } : {}),
            }),
          );
        }
      } catch (e) {
        logger.error('UserStore', 'Fetch user info error:', e);
      }
    },
    async fetchUserInfoOnce() {
      if (!this.isLoggedIn || this.hasFetchedUserInfo || this.isFetchingUserInfo) return;
      this.isFetchingUserInfo = true;
      try {
        await this.fetchUserInfo();
        this.hasFetchedUserInfo = true;
      } finally {
        this.isFetchingUserInfo = false;
      }
    },

    /**
     * 登录/添加账号成功后的统一入口：受 autoReceiveVip 设置控制，
     * 先补全用户信息再判断今日是否领取。供 handleLoginSuccess 等场景收敛调用。
     */
    async triggerAutoReceiveVipIfNeeded() {
      const { useSettingStore } = await import('@/stores/setting');
      if (!useSettingStore().autoReceiveVip) return;
      try {
        await this.fetchUserInfoOnce();
        await this.autoReceiveVipIfNeeded();
      } catch (e) {
        logger.warn('UserStore', 'triggerAutoReceiveVip failed', e);
      }
    },

    async autoReceiveVipIfNeeded() {
      if (!this.isLoggedIn || this.isAutoClaimingVip) return;
      this.isAutoClaimingVip = true;

      const toast = useToastStore();

      try {
        // 先从服务器查询今日领取状态，避免重复领取
        const { isTvipClaimedToday, isSvipClaimedToday } = await this.checkTodayClaimStatus();

        // 如果畅听和概念会员今日都已领取，直接跳过
        if (isTvipClaimedToday && isSvipClaimedToday) {
          logger.info('UserStore', 'VIP already claimed today (TVIP + SVIP), skipping auto-claim');
          return;
        }

        const today = await this.getServerToday();

        let claimSuccess = false;
        let upgradeSuccess = false;

        // 仅在畅听会员未领取时尝试领取
        if (!isTvipClaimedToday) {
          try {
            const res = await claimDayVip(today) as any;
            claimSuccess = res?.status === 1;
          } catch (e: any) {
            const msg = e?.response?.data?.error_message || e?.message || '';
            toast.warning(msg ? `自动领取失败：${msg}` : '自动领取失败，请稍后重试');
            logger.warn('UserStore', 'VIP claim: claimDayVip failed', e);
          }
        } else {
          // 畅听已领取，视为成功以继续升级流程
          claimSuccess = true;
          logger.info('UserStore', 'TVIP already claimed today, skipping claimDayVip');
        }

        // 仅在畅听已就绪且概念会员未升级时尝试升级
        if (claimSuccess && !isSvipClaimedToday) {
          try {
            const res = await upgradeDayVip() as any;
            upgradeSuccess = res?.status === 1 || res?.error_code === 297002;
          } catch (e) {
            logger.warn('UserStore', 'VIP claim: upgradeDayVip failed', e);
          }
        }

        // 有领取或升级操作时刷新用户信息
        if (!isTvipClaimedToday || (!isSvipClaimedToday && claimSuccess)) {
          try {
            await this.fetchUserInfo();
            this.hasFetchedUserInfo = true;
          } catch (e) {
            logger.warn('UserStore', 'VIP claim: fetchUserInfo failed', e);
          }
        }

        // 更新领取状态
        await this.checkTodayClaimStatus();

        // 仅对本次新领取的项目显示提示
        if (!isTvipClaimedToday && this.isTvipClaimedToday) {
          const expireDate = this.getVipExpireDate();
          toast.success(
            expireDate
              ? `自动领取成功，会员截至到 ${expireDate} 到期`
              : '畅听会员自动领取成功',
          );
        }
        if (!isSvipClaimedToday && this.isSvipClaimedToday && upgradeSuccess) {
          const svipExpire = this.getSvipExpireDate();
          toast.success(
            svipExpire
              ? `概念会员升级成功，截至到 ${svipExpire} 到期`
              : '概念会员自动升级成功',
          );
        }
      } catch (error) {
        logger.warn('UserStore', 'Auto receive VIP unexpected error:', error);
      } finally {
        this.isAutoClaimingVip = false;
      }
    },

    async checkTodayClaimStatus(): Promise<{ isTvipClaimedToday: boolean; isSvipClaimedToday: boolean }> {
      try {
        const today = await this.getServerToday();
        const recordRes = await getVipMonthRecord();
        const recordList: any[] = recordRes?.data?.list || [];

        const isTvipClaimed = recordList.some((item: any) => item.day === today);

        // 判断 SVIP 是否今日已升级：
        // 优先从记录项中查找升级标识字段，否则回退到检查 SVIP 的 vip_begin_time 是否为今日
        let isSvipClaimed = false;
        const todayRecord = recordList.find((item: any) => item.day === today);
        if (todayRecord) {
          if (todayRecord.is_upgrade || todayRecord.svip === 1 || todayRecord.product_type === 'svip') {
            isSvipClaimed = true;
          }
        }

        if (!isSvipClaimed && isTvipClaimed) {
          const vipInfo = (this.info?.extendsInfo as any)?.vip;
          const busiVip: any[] = vipInfo?.busi_vip || [];
          const svipEntry = busiVip.find((v: any) => v.product_type === 'svip' && v.is_vip === 1);
          if (svipEntry?.vip_begin_time) {
            try {
              const beginDate = new Date(svipEntry.vip_begin_time);
              const pad = (n: number) => n.toString().padStart(2, '0');
              const beginDay = `${beginDate.getFullYear()}-${pad(beginDate.getMonth() + 1)}-${pad(beginDate.getDate())}`;
              isSvipClaimed = beginDay === today;
            } catch {
              // 解析失败忽略
            }
          }
        }

        this.isTvipClaimedToday = isTvipClaimed;
        this.isSvipClaimedToday = isSvipClaimed;

        return { isTvipClaimedToday: isTvipClaimed, isSvipClaimedToday: isSvipClaimed };
      } catch (e) {
        logger.warn('UserStore', 'Failed to check claim status:', e);
        return { isTvipClaimedToday: this.isTvipClaimedToday, isSvipClaimedToday: this.isSvipClaimedToday };
      }
    },

    setClaimStatus(tvip: boolean, svip: boolean) {
      this.isTvipClaimedToday = tvip;
      this.isSvipClaimedToday = svip;
    },

    getVipExpireDate(): string | null {
      const vipInfo = (this.info?.extendsInfo as any)?.vip;
      const busiVip: any[] = vipInfo?.busi_vip || [];
      const tvip = busiVip.find((v: any) => v.product_type === 'tvip' && v.is_vip === 1);
      if (!tvip?.vip_end_time) return null;
      try {
        const d = new Date(tvip.vip_end_time);
        if (isNaN(d.getTime())) return null;
        const pad = (n: number) => n.toString().padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
      } catch {
        return null;
      }
    },

    getSvipExpireDate(): string | null {
      const vipInfo = (this.info?.extendsInfo as any)?.vip;
      const busiVip: any[] = vipInfo?.busi_vip || [];
      const svip = busiVip.find((v: any) => v.product_type === 'svip' && v.is_vip === 1);
      if (!svip?.vip_end_time) return null;
      try {
        const d = new Date(svip.vip_end_time);
        if (isNaN(d.getTime())) return null;
        const pad = (n: number) => n.toString().padStart(2, '0');
        return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
      } catch {
        return null;
      }
    },
    logout() {
      this.info = null;
      this.isLoggedIn = false;
      this.hasFetchedUserInfo = false;
      this.isFetchingUserInfo = false;
      this.isTvipClaimedToday = false;
      this.isSvipClaimedToday = false;
      this.isAutoClaimingVip = false;
      this.followedArtistIds = new Set();
      this.hasFetchedFollowedArtists = false;
      // 完全登出：清空账号列表与活跃账号标记
      this.accounts = [];
      this.activeUserId = null;
    },

    // ── 多账号（用户切换）actions ──

    /**
     * 将当前 info 写入 accounts 列表。
     * 同 userid 覆盖更新（保留原 savedAt），否则新增。
     */
    saveCurrentAccount() {
      if (!this.info?.userid || !this.info?.token) return;
      const acc = accountFromInfo(this.info);
      const idx = this.accounts.findIndex((a) => a.userid === acc.userid);
      if (idx >= 0) {
        // 保留原 savedAt，更新其余字段
        this.accounts.splice(idx, 1, { ...acc, savedAt: this.accounts[idx].savedAt });
      } else {
        this.accounts.push(acc);
      }
      this.activeUserId = acc.userid;
    },

    /**
     * 切换到指定账号。切换只替换 info，不影响 player/playlist/setting/device。
     * @param options.preserveCurrent 切换前是否把当前账号最新 info 落盘（默认 true）。
     *   退出当前账号时传 false，否则被移除的账号会被 saveCurrentAccount 重新写回 accounts。
     * @returns true=切换成功；false=目标账号 token 已过期（由调用方提示并跳登录）
     */
    async switchToAccount(
      userid: number,
      options?: { preserveCurrent?: boolean },
    ): Promise<boolean> {
      const target = this.accounts.find((a) => a.userid === userid);
      if (!target) {
        logger.warn('UserStore', 'switchToAccount: account not found', userid);
        return false;
      }
      // 切换前检测 token 是否过期
      if (isAccountExpired(target)) {
        logger.warn('UserStore', 'switchToAccount: account token expired', userid);
        return false;
      }
      // 切换前先把当前 info 落盘，避免丢失最新状态（preserveCurrent=false 时跳过，
      // 用于退出当前账号场景，避免被移除的账号被 saveCurrentAccount 重新写回 accounts）。
      const preserveCurrent = options?.preserveCurrent !== false;
      if (preserveCurrent && this.info?.userid && this.info.userid !== userid) {
        this.saveCurrentAccount();
      }
      // 清空当前用户私有缓存（关注列表、VIP 领取状态、信息拉取标记）
      this.followedArtistIds = new Set();
      this.hasFetchedFollowedArtists = false;
      this.hasFetchedUserInfo = false;
      this.isTvipClaimedToday = false;
      this.isSvipClaimedToday = false;
      // 用目标账号快照装载 info —— 请求层会自动使用新 token/userid
      this.setUserInfo(minimalInfoFromAccount(target));
      this.activeUserId = userid;
      // 异步补全 detail/vip 等完整信息；若开启自动领取则顺带领取今日会员
      void (async () => {
        try {
          await this.fetchUserInfoOnce();
        } catch (e) {
          logger.warn('UserStore', 'switchToAccount: fetchUserInfo failed', e);
        }
        try {
          const { useSettingStore } = await import('@/stores/setting');
          if (useSettingStore().autoReceiveVip) {
            await this.autoReceiveVipIfNeeded();
          }
        } catch (e) {
          logger.warn('UserStore', 'switchToAccount: autoReceiveVip failed', e);
        }
      })();
      return true;
    },

    /**
     * 退出指定账号（统一入口）。
     * - 从 accounts 列表移除
     * - 若退出的是当前活跃账号：
     *   - 还有其他账号 → 自动切到 savedAt 最早的一个（保持已登录态）
     *   - 没有其他账号 → 完全登出（清空 info）
     */
    logoutAccount(userid: number) {
      const idx = this.accounts.findIndex((a) => a.userid === userid);
      if (idx < 0) return;
      this.accounts.splice(idx, 1);

      if (this.activeUserId !== userid) return;

      if (this.accounts.length > 0) {
        // 切到剩余账号中最早加入的一个；preserveCurrent=false 避免把刚退出的账号存回
        const next = [...this.accounts].sort((a, b) => a.savedAt - b.savedAt)[0];
        void this.switchToAccount(next.userid, { preserveCurrent: false });
      } else {
        // 无剩余账号，完全登出
        this.activeUserId = null;
        this.logout();
      }
    },

    isArtistFollowed(artistId: string | number): boolean {
      return this.followedArtistIds.has(String(artistId));
    },

    addFollowedArtist(artistId: string | number) {
      this.followedArtistIds = new Set([...this.followedArtistIds, String(artistId)]);
    },

    removeFollowedArtist(artistId: string | number) {
      const next = new Set(this.followedArtistIds);
      next.delete(String(artistId));
      this.followedArtistIds = next;
    },

    async fetchFollowedArtists() {
      if (!this.isLoggedIn) return;
      try {
        const res = await getUserFollow();
        if (res && typeof res === 'object' && 'data' in res) {
          const data = (res as { data?: { lists?: unknown[] } }).data;
          const lists = Array.isArray(data?.lists) ? data.lists : [];
          const ids = new Set<string>();
          for (const item of lists) {
            const record = item as Record<string, unknown>;
            const id = String(record.singerid ?? record.userid ?? record.id ?? '');
            if (id) ids.add(id);
          }
          this.followedArtistIds = ids;
          this.hasFetchedFollowedArtists = true;
        }
      } catch (e) {
        logger.warn('UserStore', 'Fetch followed artists failed', e);
      }
    },

    async ensureFollowedArtists() {
      if (this.hasFetchedFollowedArtists) return;
      await this.fetchFollowedArtists();
    },

    async getServerToday(): Promise<string> {
      try {
        const res = await getServerNow();
        if (res && typeof res === 'object') {
          const record = res as unknown as Record<string, unknown>;
          const source = (
            record.data && typeof record.data === 'object' ? record.data : record
          ) as Record<string, unknown>;
          const candidates = [
            source.now,
            source.time,
            source.timestamp,
            source.server_time,
            source.serverTime,
          ];
          for (const candidate of candidates) {
            const value = Number(candidate);
            if (Number.isFinite(value) && value > 0) {
              // 服务器返回的是秒级或毫秒级时间戳
              const ms = value > 1e12 ? value : value * 1000;
              // 使用北京时间（UTC+8）格式化日期
              const date = new Date(ms);
              const offset = 8 * 60;
              const local = new Date(date.getTime() + offset * 60 * 1000);
              return local.toISOString().split('T')[0];
            }
          }
        }
      } catch (e) {
        logger.warn('UserStore', 'Failed to get server time, using local time', e);
      }
      // 兜底：使用本地时间（北京时间）
      const now = new Date();
      const offset = 8 * 60;
      const local = new Date(now.getTime() + offset * 60 * 1000);
      return local.toISOString().split('T')[0];
    },
  },
  persist: {
    omit: [
      'hasFetchedUserInfo',
      'isFetchingUserInfo',
      'isAutoClaimingVip',
      'followedArtistIds',
      'hasFetchedFollowedArtists',
    ],
  },
});
