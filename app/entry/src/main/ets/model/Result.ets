/**
 * Result —— 跨层统一返回值包装。
 *
 * 职责：给 Service 层一个不发异常也能表达失败的返回类型，避免页面层 try/catch 满天飞。
 *
 * 依据：`docs/APPENDIX-B-data-and-api.md` §4。
 * 约定：`ok = true` 时 `data` 必须有值；`ok = false` 时 `code` + `message` 说明原因。
 */
export interface AppResult<T> {
  ok: boolean;
  data?: T;
  code?: string;
  message?: string;
}

/**
 * 构造成功结果。
 * @param data 业务数据
 */
export function ok<T>(data: T): AppResult<T> {
  return { ok: true, data };
}

/**
 * 构造失败结果。
 * @param code 机器可读错误码（如 `E_DB`）
 * @param message 给人看的说明
 */
export function fail<T>(code: string, message: string): AppResult<T> {
  return { ok: false, code, message };
}
