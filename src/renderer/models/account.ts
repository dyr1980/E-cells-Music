/**
 * 已登录账号快照：仅保留切换账号所需的最少字段。
 * 不存 extendsInfo/detail/vip 等大对象，切换后通过 fetchUserInfo() 重新拉取完整信息。
 */
export interface Account {
  /** 主键，唯一（对齐 User.userid） */
  userid: number;
  /** 鉴权令牌 */
  token: string;
  /** 展示用昵称 */
  nickname?: string;
  /** 头像 URL */
  pic?: string;
  /** 等级（列表展示） */
  p_grade?: number;
  /** 微信登录等附加鉴权字段（若有） */
  t1?: string;
  /** token 过期时间戳(ms)，无则视为永久 */
  expires?: number;
  /** 加入账号列表的时间戳，用于排序 */
  savedAt: number;
}

/**
 * 由 Account 构造的最小可用 UserInfo。
 * 足够 request.ts 的 buildAuthHeader 与 userStore.setUserInfo 使用。
 */
export interface MinimalUserInfo {
  userid: number;
  userId?: number;
  token: string;
  nickname?: string;
  pic?: string;
  p_grade?: number;
  t1?: string;
  expires?: number;
}
