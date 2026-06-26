import { getSongMv } from '@/api/video';
import { search } from '@/api/search';
import type { Song } from '@/models/song';

// ── 工具 ──
const toRecord = (value: unknown): Record<string, unknown> | undefined => {
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return undefined;
};

// ── 从 record 中提取 hash 的公共辅助函数 ──
const readHashFromRecord = (record: Record<string, unknown> | undefined): string => {
  if (!record) return '';
  return String(record.hash ?? record.video_hash ?? record.mv_hash ?? record.mvhash ?? '').trim();
};

// ── 策略一：通过 getSongMv(albumAudioId) 直接从歌曲关联获取 MV hash ──
// 响应格式兼容：
//   A) { data: [[{ hash, video_hash, ... }]] }  → 嵌套数组
//   B) { data: { mkv: { hash, ... } } }          → 对象格式（fields=mkv 时）
const tryGetMvHashViaAudioId = async (
  albumAudioId: string | number,
  signal?: AbortSignal,
): Promise<string> => {
  try {
    const res = await getSongMv(albumAudioId, 'mkv', signal);
    const root = toRecord(res);
    const data = root?.data;

    // 路径 A：嵌套数组格式  { data: [[{ hash, ... }]] }
    if (Array.isArray(data) && data.length > 0) {
      const firstGroup = data[0];
      if (Array.isArray(firstGroup) && firstGroup.length > 0) {
        const record = toRecord(firstGroup[0]);
        const hash = readHashFromRecord(record);
        if (hash) return hash;
      }
    }

    // 路径 B：对象格式  { data: { mkv: { hash, ... }, ... } }  或  { data: { hash, ... } }
    if (typeof data === 'object' && data !== null && !Array.isArray(data)) {
      const dataRecord = data as Record<string, unknown>;
      // 优先取 mkv 子键（对应 fields=mkv）
      const mkvHash = readHashFromRecord(toRecord(dataRecord.mkv));
      if (mkvHash) return mkvHash;
      // 回退到 data 顶层
      const directHash = readHashFromRecord(dataRecord);
      if (directHash) return directHash;
    }

    return '';
  } catch {
    return '';
  }
};

// ── 策略二（回退）：通过搜索 API 按歌名+歌手搜索，匹配最适合的 MV ──
const extractMvList = (payload: unknown): unknown[] => {
  const record = toRecord(payload);
  const data = toRecord(record?.data);
  const lists = data?.lists ?? data?.list ?? record?.lists ?? record?.list;
  return Array.isArray(lists) ? lists : [];
};

const tryGetMvHashViaSearch = async (
  title: string,
  artist: string,
  signal?: AbortSignal,
): Promise<string> => {
  try {
    const res = await search(`${title} ${artist}`, 'mv', 1, 5, signal);
    const mvList = extractMvList(res);
    if (mvList.length === 0) return '';

    const t = title.trim().toLowerCase();
    const a = artist.trim().toLowerCase();

    // 第一轮：歌名+歌手 双匹配
    for (const item of mvList) {
      const record = toRecord(item);
      if (!record) continue;
      const hash = String(record.MvHash ?? '').trim();
      if (!hash) continue;
      const mvName = String(record.MvName ?? '').toLowerCase();
      const singerName = String(record.SingerName ?? '').toLowerCase();
      if (t && mvName.includes(t) && a && singerName.includes(a)) {
        return hash;
      }
    }

    // 第二轮：歌名或歌手 单匹配
    for (const item of mvList) {
      const record = toRecord(item);
      if (!record) continue;
      const hash = String(record.MvHash ?? '').trim();
      if (!hash) continue;
      const mvName = String(record.MvName ?? '').toLowerCase();
      const singerName = String(record.SingerName ?? '').toLowerCase();
      if ((t && mvName.includes(t)) || (a && singerName.includes(a))) {
        return hash;
      }
    }

    // 最终回退：第一个有 hash 的结果
    const first = toRecord(mvList[0]);
    return first ? String(first.MvHash ?? '').trim() : '';
  } catch {
    return '';
  }
};

// ── 并发限制器（支持取消）──
const createConcurrencyLimiter = (limit: number, signal?: AbortSignal) => {
  let running = 0;
  const queue: (() => void)[] = [];

  const release = () => {
    running--;
    // 已取消则不再启动队列中的任务
    if (signal?.aborted) {
      queue.length = 0;
      return;
    }
    const next = queue.shift();
    if (next) {
      running++;
      next();
    }
  };

  return <T>(fn: () => Promise<T>): Promise<T> =>
    new Promise((resolve, reject) => {
      // 已取消：直接拒绝，调用方 catch 后返回空即可
      if (signal?.aborted) {
        reject(new DOMException('Aborted', 'AbortError'));
        return;
      }
      const run = () => {
        fn().then(resolve, reject).finally(release);
      };
      if (running < limit) {
        running++;
        run();
      } else {
        queue.push(run);
      }
    });
};

// ── 去重 key ──
const buildSongKey = (song: Song): string =>
  `${(song.title ?? '').trim()}||${(song.artist ?? '').trim()}`.toLowerCase();

export interface EnrichMvOptions {
  /** 并发上限，默认 5 */
  concurrency?: number;
  /** 取消信号，aborted 时中止后续请求 */
  signal?: AbortSignal;
  /** 单首歌拿到 MV 后的回调（用于增量触发响应式更新） */
  onSongEnriched?: () => void;
}

/**
 * 异步批量匹配并回填歌曲的 mvHash 字段
 *
 * 策略：
 *   1. 优先用 getSongMv(mixSongId) 直接从歌曲关联获取 MV（精准、快速）
 *   2. 回退到 search(title+artist, 'mv') 搜索匹配
 *   3. 去重：相同歌名+歌手用同一次结果
 *   4. 增量回填：每首歌拿到结果立即写入，并通过 onSongEnriched 通知调用方刷新视图
 *   5. 可取消：传入 signal 后，aborted 时立即停止发起剩余请求
 *
 * @param songs   歌曲列表（原地修改 mvHash）
 * @param options 并发上限 / 取消信号 / 增量回调
 */
export async function enrichSongsWithMv(
  songs: Song[],
  options: EnrichMvOptions = {},
): Promise<void> {
  const { concurrency = 5, signal, onSongEnriched } = options;
  const needEnrich = songs.filter((s) => !(s.mvHash ?? '').trim());
  if (needEnrich.length === 0 || signal?.aborted) return;

  // 去重
  const unique = new Map<
    string,
    { title: string; artist: string; mixSongId: number; group: Song[] }
  >();
  for (const song of needEnrich) {
    const key = buildSongKey(song);
    const existing = unique.get(key);
    if (existing) {
      existing.group.push(song);
    } else {
      unique.set(key, {
        title: (song.title ?? '').trim(),
        artist: (song.artist ?? '').trim(),
        mixSongId: Number(song.mixSongId ?? 0),
        group: [song],
      });
    }
  }

  const entries = Array.from(unique.values());
  const limiter = createConcurrencyLimiter(concurrency, signal);

  // 增量回填：同组歌曲共享同一个 hash 结果
  const applyHash = (entry: (typeof entries)[number], hash: string) => {
    for (const song of entry.group) {
      if (!song.mvHash?.trim()) song.mvHash = hash;
    }
    onSongEnriched?.();
  };

  const tasks = entries.map((entry) =>
    limiter(async () => {
      // 策略一：优先用音频ID直接获取MV
      if (entry.mixSongId > 0) {
        const hash = await tryGetMvHashViaAudioId(entry.mixSongId, signal);
        if (hash) {
          applyHash(entry, hash);
          return;
        }
      }
      // 已取消则不再发起搜索请求
      if (signal?.aborted) return;

      // 策略二：回退到搜索匹配
      const hash = await tryGetMvHashViaSearch(entry.title, entry.artist, signal);
      if (hash) {
        applyHash(entry, hash);
      }
    }).catch(() => {
      /* 取消或单首失败，静默忽略 */
    }),
  );

  await Promise.allSettled(tasks);
}
