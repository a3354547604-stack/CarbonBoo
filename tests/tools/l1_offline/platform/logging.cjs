/**
 * 日志与错误垫片 —— `@kit.PerformanceAnalysisKit` 的 `hilog` 与 `@kit.BasicServicesKit` 的 `BusinessError`。
 *
 * `hilog` 默认**静默**（只在 `L1_VERBOSE=1` 时打到 stderr）：被执行器加载的 Service 会在正常路径上
 * 打不少 info，"看着像有输出"不等于"断言通过"，把它压掉才能让 stdout 只剩结论行。
 *
 * `BusinessError` 只是 `Error` 的子类（带 `code`），被测代码用它区分「可预期的业务失败」与「真异常」。
 */

'use strict';

const verbose = process.env.L1_VERBOSE === '1';

function sink(level) {
  return (domain, tag, format, ...args) => {
    if (!verbose) {
      return;
    }
    let msg = String(format);
    let i = 0;
    msg = msg.replace(/%[sdif%]/g, (m) => {
      if (m === '%%') {
        return '%';
      }
      const v = args[i];
      i += 1;
      return typeof v === 'undefined' ? String(m) : String(v);
    });
    process.stderr.write(`[${level}] ${tag}: ${msg}\n`);
  };
}

const hilog = {
  debug: sink('D'),
  info: sink('I'),
  warn: sink('W'),
  error: sink('E'),
  fatal: sink('F'),
  isLoggable(domain, tag, level) {
    return verbose;
  },
  LogLevel: { DEBUG: 3, INFO: 4, WARN: 5, ERROR: 6, FATAL: 7 },
};

class BusinessError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'BusinessError';
    this.code = code;
  }
}

module.exports = { hilog, BusinessError };
