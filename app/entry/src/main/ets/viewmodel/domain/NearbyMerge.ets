/**
 * 家庭碳积分合并（NearbyMerge）—— 纯函数层，无 IO、无状态、无异常。
 *
 * 职责：把「本机 + 若干对端设备」的只读快照，校验、去重、排序、截断，再定点求和成
 *      一份家庭合并汇总。**只做算术，不碰数据库、不碰网络、不碰分布式 API**。
 *
 * 为什么单独成层（这里的设计取舍不是风格问题）：
 *  ① 这是整个近场协同里**唯一值得被反复回归的算法**：非法行、重复行、时钟倒挂、
 *     恶意超大量级，全靠这几条规则收敛。放在纯函数里，hypium 用例可以直接喂脏数据，
 *     不需要真机、不需要 KV、不需要组网（无真机时仍能验证，见 m01999 的用户决策）。
 *  ② 数值口径与主账本一致：减排量用 `Dec` 定点累加后 4 位小数，**禁止浮点累加**
 *     （AGENTS.md §3）；积分与记录数是整数，非法小数一律判为脏数据丢弃而不是四舍五入
 *     —— 四舍五入会把「对端算错了」伪装成「数据没问题」。
 *  ③ 合并是**只读视图**：不写回本机账本，不产生积分流水，因此不可能破坏铁律 4
 *     「积分单向可追溯」。这条约束也解释了为什么这里只传统计快照、不传明细。
 */
import { Dec, roundHalfUp } from '../../util/DecimalUtil';
import { asObject, JsonObject, num, str } from '../../util/JsonUtil';
import { DeviceContribution } from '../distributed/DistributedPort';

/** 参与合并的设备上限：多到离谱的对端一律丢弃（防御恶意/异常的对端反复广播）。 */
export const MAX_CONTRIBUTIONS: number = 32;

/** 单机记录条数上限（超过即视为脏数据）。 */
export const MAX_RECORD_COUNT: number = 1000000;

/** 单机积分净额绝对值上限。 */
export const MAX_POINTS: number = 100000000;

/** 单机减排量上限（kgCO₂e）。 */
export const MAX_REDUCTION_KG: number = 1000000;

/** 设备标识最大长度（`deviceId` 超长视为脏数据）。 */
export const MAX_DEVICE_ID_LENGTH: number = 64;

/** 设备名最大长度（超出截断，不丢弃——名字只是展示用）。 */
export const MAX_DEVICE_NAME_LENGTH: number = 32;

/** 单条贡献的 JSON 最大长度（超出直接不解析，防御超大 payload）。 */
export const MAX_CONTRIBUTION_JSON_LENGTH: number = 1024;

/** 减排量保留小数位（与主账本、附录 A §3.4 同口径）。 */
export const REDUCTION_PLACES: number = 4;

/** 家庭碳积分合并汇总。 */
export interface FamilySummary {
  /** 参与合并的设备数（已去重、已剔除非法行）。 */
  devices: number;
  /** 记录条数合计。 */
  recordCount: number;
  /** 减排量合计（kgCO₂e，4 位小数）。 */
  reductionKg: number;
  /** 积分净额合计（整数，可为负）。 */
  points: number;
}

/** 一次合并的明细统计（验收 D6-9 要展示「合并了几台、丢了几条」）。 */
export interface MergeReport {
  /** 合并后的贡献列表（本机在前，其余按 `deviceId` 升序）。 */
  contributions: DeviceContribution[];
  /** 汇总。 */
  summary: FamilySummary;
  /** 校验失败被丢弃的条数。 */
  invalidCount: number;
  /** 同一 `deviceId` 重复出现、被 LWW 覆盖的条数。 */
  duplicateCount: number;
}

/** 空汇总（未组网 / 无数据时的稳定返回值，避免页面拿到 undefined）。 */
export function emptySummary(): FamilySummary {
  const out: FamilySummary = { devices: 0, recordCount: 0, reductionKg: 0, points: 0 };
  return out;
}

/** 是否是有限的整数值（拒绝 `NaN` / `Infinity` / 小数）。 */
function isIntInRange(v: number, min: number, max: number): boolean {
  if (!Number.isFinite(v)) {
    return false;
  }
  if (Math.floor(v) !== v) {
    return false;
  }
  return v >= min && v <= max;
}

/** 是否是有限数值且在区间内（允许小数，如减排量）。 */
function isNumInRange(v: number, min: number, max: number): boolean {
  if (!Number.isFinite(v)) {
    return false;
  }
  return v >= min && v <= max;
}

/**
 * 单条贡献是否合法。
 *
 * 规则（任意一条不满足即丢弃，**不做任何"修正"**）：
 *  - `deviceId` 非空且 ≤ 64 字符；
 *  - `deviceName` 非空（超长由 `normalize` 截断，此处只拒空）；
 *  - `recordCount` 为 [0, 1e6] 的整数；
 *  - `points` 为 [-1e8, 1e8] 的整数；
 *  - `reductionKg` 为 [0, 1e6] 的有限数；
 *  - `updatedAt` 为 > 0 的整数（毫秒时间戳）。
 */
export function isValidContribution(c: DeviceContribution): boolean {
  if (c === undefined || c === null) {
    return false;
  }
  if (c.deviceId.length === 0 || c.deviceId.length > MAX_DEVICE_ID_LENGTH) {
    return false;
  }
  if (c.deviceName.length === 0) {
    return false;
  }
  if (!isIntInRange(c.recordCount, 0, MAX_RECORD_COUNT)) {
    return false;
  }
  if (!isIntInRange(c.points, -MAX_POINTS, MAX_POINTS)) {
    return false;
  }
  if (!isNumInRange(c.reductionKg, 0, MAX_REDUCTION_KG)) {
    return false;
  }
  if (!isIntInRange(c.updatedAt, 1, Number.MAX_SAFE_INTEGER)) {
    return false;
  }
  return true;
}

/** 生成一份防御性拷贝（防止调用方持有的对象事后被改，污染内部结果）。 */
function copyOf(c: DeviceContribution): DeviceContribution {
  const name: string = c.deviceName.length > MAX_DEVICE_NAME_LENGTH
    ? c.deviceName.substring(0, MAX_DEVICE_NAME_LENGTH)
    : c.deviceName;
  const out: DeviceContribution = {
    deviceId: c.deviceId,
    deviceName: name,
    recordCount: c.recordCount,
    reductionKg: roundHalfUp(c.reductionKg, REDUCTION_PLACES),
    points: c.points,
    updatedAt: c.updatedAt
  };
  return out;
}

/** 在数组中找 `deviceId` 的下标；找不到返回 -1。 */
function indexOfDevice(list: DeviceContribution[], deviceId: string): number {
  for (let i = 0; i < list.length; i++) {
    if (list[i].deviceId === deviceId) {
      return i;
    }
  }
  return -1;
}

/** 按 `deviceId` 升序比较（避免依赖读入顺序，结果可复现）。 */
function compareDeviceId(a: DeviceContribution, b: DeviceContribution): number {
  if (a.deviceId < b.deviceId) {
    return -1;
  }
  if (a.deviceId > b.deviceId) {
    return 1;
  }
  return 0;
}

/**
 * 清洗贡献列表：剔除非法行 → 按 `deviceId` 去重（LWW，`updatedAt` 大者胜；相等时保留先到者）
 * → 按 `deviceId` 升序 → 截断到 `MAX_CONTRIBUTIONS`。
 *
 * 为什么 LWW 相等时保留先到者：本机永远排在最前，因此「本机与对端 `updatedAt` 完全相同」
 * 的平局会稳定地判给本机，不会出现两台设备互相覆盖导致界面数字来回跳。
 * @param list 待清洗的贡献（可含非法行、重复行）
 * @returns 清洗后的新数组（不与入参共享对象）
 */
export function normalize(list: DeviceContribution[]): DeviceContribution[] {
  const picked: DeviceContribution[] = [];
  for (let i = 0; i < list.length; i++) {
    const c: DeviceContribution = list[i];
    if (!isValidContribution(c)) {
      continue;
    }
    const at: number = indexOfDevice(picked, c.deviceId);
    if (at < 0) {
      picked.push(copyOf(c));
    } else if (c.updatedAt > picked[at].updatedAt) {
      picked[at] = copyOf(c);
    }
  }
  picked.sort(compareDeviceId);
  if (picked.length > MAX_CONTRIBUTIONS) {
    return picked.slice(0, MAX_CONTRIBUTIONS);
  }
  return picked;
}

/**
 * 定点求和（**禁止浮点累加**，AGENTS.md §3）。
 * 输入需先经 `normalize`，本函数不再做校验，只做算术。
 */
export function summarize(list: DeviceContribution[]): FamilySummary {
  let recordCount: number = 0;
  let points: number = 0;
  let reduction: Dec = Dec.fromInt(0);
  for (let i = 0; i < list.length; i++) {
    recordCount += list[i].recordCount;
    points += list[i].points;
    reduction = reduction.add(Dec.from(list[i].reductionKg));
  }
  const out: FamilySummary = {
    devices: list.length,
    recordCount: recordCount,
    reductionKg: reduction.roundHalfUp(REDUCTION_PLACES).toNumber(REDUCTION_PLACES),
    points: points
  };
  return out;
}

/** 两份汇总是否等价（用于避免界面无谓刷新）。 */
export function sameSummary(a: FamilySummary, b: FamilySummary): boolean {
  if (a.devices !== b.devices || a.recordCount !== b.recordCount || a.points !== b.points) {
    return false;
  }
  return roundHalfUp(a.reductionKg, REDUCTION_PLACES) === roundHalfUp(b.reductionKg, REDUCTION_PLACES);
}

/**
 * 合并本机与对端贡献，并返回明细统计。
 *
 * 合并顺序：本机 → 对端。本机永远参与（即使它对端一份都收不到），
 * 因此未组网时界面也能显示「本机 1 台」的家庭视图，而不是空面板。
 * @param local 本机贡献（不可为 undefined；调用方用 `localContribution()` 生成）
 * @param peers 对端贡献（可含非法行、重复行）
 */
export function mergeReport(local: DeviceContribution, peers: DeviceContribution[]): MergeReport {
  const all: DeviceContribution[] = [];
  all.push(local);
  for (let i = 0; i < peers.length; i++) {
    all.push(peers[i]);
  }
  let invalidCount: number = 0;
  for (let i = 0; i < all.length; i++) {
    if (!isValidContribution(all[i])) {
      invalidCount++;
    }
  }
  const valid: DeviceContribution[] = [];
  for (let i = 0; i < all.length; i++) {
    if (isValidContribution(all[i])) {
      valid.push(all[i]);
    }
  }
  const contributions: DeviceContribution[] = normalize(valid);
  // 重复 = 合法条数 − 去重后条数（同一个 deviceId 出现多次即被 LWW 覆盖）。
  const duplicateCount: number = valid.length - contributions.length;
  const out: MergeReport = {
    contributions: contributions,
    summary: summarize(contributions),
    invalidCount: invalidCount,
    duplicateCount: duplicateCount
  };
  return out;
}

/**
 * 序列化一条贡献（对端广播用的线上格式）。
 *
 * 显式逐个字段写出，而不是直接 `JSON.stringify(c)`：这样线上字段名与顺序是**契约**，
 * 将来给 `DeviceContribution` 加字段不会静默改变广播内容（加字段必须同时改这里）。
 */
export function serializeContribution(c: DeviceContribution): string {
  const wire: DeviceContribution = {
    deviceId: c.deviceId,
    deviceName: c.deviceName.length > MAX_DEVICE_NAME_LENGTH
      ? c.deviceName.substring(0, MAX_DEVICE_NAME_LENGTH)
      : c.deviceName,
    recordCount: c.recordCount,
    reductionKg: roundHalfUp(c.reductionKg, REDUCTION_PLACES),
    points: c.points,
    updatedAt: c.updatedAt
  };
  return JSON.stringify(wire);
}

/**
 * 解析一条对端贡献（**防御式**，任何异常一律返回 `undefined`）。
 *
 * 为什么不用 `JSON.parse` + `as`：`as` 在本仓库被 AGENTS.md §7.1 明令禁止，
 * 且对端内容是不可信输入（可能是旧版本、可能是改过的包），必须逐字段校验。
 * @param raw 线上 JSON 字符串
 */
export function parseContribution(raw: string): DeviceContribution | undefined {
  if (raw.length === 0 || raw.length > MAX_CONTRIBUTION_JSON_LENGTH) {
    return undefined;
  }
  let parsed: Object;
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    return undefined;
  }
  let out: DeviceContribution | undefined = undefined;
  try {
    const o: JsonObject = asObject(parsed, 'contribution');
    const c: DeviceContribution = {
      deviceId: str(o, 'deviceId', 'contribution'),
      deviceName: str(o, 'deviceName', 'contribution'),
      recordCount: num(o, 'recordCount', 'contribution'),
      reductionKg: num(o, 'reductionKg', 'contribution'),
      points: num(o, 'points', 'contribution'),
      updatedAt: num(o, 'updatedAt', 'contribution')
    };
    if (isValidContribution(c)) {
      out = copyOf(c);
    }
  } catch (e) {
    out = undefined;
  }
  return out;
}
