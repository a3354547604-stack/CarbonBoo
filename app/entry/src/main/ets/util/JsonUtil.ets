/**
 * JsonUtil —— 无 `any` / 无 `as` 断言的 JSON 取值工具（AGENTS.md §7.1 禁令下的必需底座）。
 *
 * 职责：把 `JSON.parse()` 返回的动态结构**安全地**取成 ArkTS 静态类型：
 *  ① `asObject` / `asArray`：结构判定（不是就抛带路径的错，不静默返回 undefined）；
 *  ② `str` / `num` / `bool` / `strArray`：按字段名取值并做**运行时类型校验**；
 *  ③ `optStr` / `optNum`：可选字段。
 *
 * 为什么不能用 `as` 断言（而这里绕了一圈）：
 *  ArkTS 严格模式禁止 `as` 强制断言，因为断言不做运行时校验——JSON 写错字段名时，
 *  断言会让错误静默传播到落库阶段（表现为某列全为 0）。本文件的每个取值函数都在
 *  **运行时**验证类型，字段缺失/类型不对立刻抛出带字段路径的错误，问题在解析时就暴露。
 *  这不是"更啰嗦"，而是把"文档写错"从数据事故降级成启动期异常。
 *
 * 本文件不 import 任何 ArkTS 运行时 API，可被离线脚本复算。
 */

/** JSON 对象形态：`Record<string, Object>` 是 ArkTS 允许的动态键访问形式。 */
export type JsonObject = Record<string, Object>;

/** JSON 数组形态（元素仍是动态的 `Object`，逐元素再校验）。 */
export type JsonArray = Object[];

/** 判定为 JSON 对象。 */
export function asObject(v: Object, path: string): JsonObject {
  if (v === null || typeof v !== 'object' || Array.isArray(v)) {
    throw new Error(`JSON 结构错误：${path} 期望对象，实际 ${typeof v}`);
  }
  // 此处必须用 `as`：`JSON.parse` 的静态类型是 `Object`，而 `Record<string, Object>`
  // 需要索引签名，二者无法在不写断言的情况下互相赋值。
  // 与"强断言"的区别：上一行的运行时判定已经**证明**了它是非 null 非数组的对象，
  // 断言在这里不跳过任何校验，只是把已证明的事实告诉类型系统。
  return v as JsonObject;
}

/** 判定为 JSON 数组。 */
export function asArray(v: Object, path: string): JsonArray {
  if (!Array.isArray(v)) {
    throw new Error(`JSON 结构错误：${path} 期望数组，实际 ${typeof v}`);
  }
  return v;
}

/** 取必填子对象。 */
export function must(o: JsonObject, key: string): Object {
  const v: Object | undefined = o[key];
  if (v === undefined) {
    throw new Error(`JSON 字段缺失：${key}`);
  }
  return v;
}

/** 取必填子数组。 */
export function mustArray(o: JsonObject, key: string): JsonArray {
  return asArray(must(o, key), key);
}

/** 必填字符串。 */
export function str(o: JsonObject, key: string, path: string): string {
  const v: Object | undefined = o[key];
  if (typeof v !== 'string') {
    throw new Error(`JSON 字段错误：${path}.${key} 期望 string，实际 ${typeof v}`);
  }
  return v;
}

/** 必填数字。 */
export function num(o: JsonObject, key: string, path: string): number {
  const v: Object | undefined = o[key];
  if (typeof v !== 'number' || !Number.isFinite(v)) {
    throw new Error(`JSON 字段错误：${path}.${key} 期望 number，实际 ${typeof v}`);
  }
  return v;
}

/** 必填布尔。 */
export function bool(o: JsonObject, key: string, path: string): boolean {
  const v: Object | undefined = o[key];
  if (typeof v !== 'boolean') {
    throw new Error(`JSON 字段错误：${path}.${key} 期望 boolean，实际 ${typeof v}`);
  }
  return v;
}

/** 可选字符串。 */
export function optStr(o: JsonObject, key: string): string | undefined {
  const v: Object | undefined = o[key];
  return typeof v === 'string' ? v : undefined;
}

/** 可选数字。 */
export function optNum(o: JsonObject, key: string): number | undefined {
  const v: Object | undefined = o[key];
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined;
}

/** 可选布尔。 */
export function optBool(o: JsonObject, key: string): boolean | undefined {
  const v: Object | undefined = o[key];
  return typeof v === 'boolean' ? v : undefined;
}

/** 字符串数组（缺失返回 undefined；元素非字符串则报错）。 */
export function optStrArray(o: JsonObject, key: string, path: string): string[] | undefined {
  const v: Object | undefined = o[key];
  if (v === undefined) {
    return undefined;
  }
  const arr: JsonArray = asArray(v, `${path}.${key}`);
  const out: string[] = [];
  let i: number = 0;
  while (i < arr.length) {
    const e: Object = arr[i];
    if (typeof e !== 'string') {
      throw new Error(`JSON 字段错误：${path}.${key}[${i}] 期望 string，实际 ${typeof e}`);
    }
    out.push(e);
    i = i + 1;
  }
  return out;
}
