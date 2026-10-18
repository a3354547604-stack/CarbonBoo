/**
 * hypium 垫片 —— `@ohos/hypium` 的离线实现（仅 describe / it / expect）。
 *
 * 红线（写在最前，评审请先看这段）：
 *  - 本文件只实现**测试框架**本身，不包含任何被测业务逻辑；
 *  - 匹配器只实现仓库真实用到的集合（`grep -ho "expect(...)\.\w*"` 实测：assertEqual 89 /
 *    assertTrue 73 / assertFalse 16），另外补几个同类常用匹配器；
 *  - **未知匹配器一律抛错**（用 Proxy 兜住），绝不静默通过 —— 这是「不许用假实现制造通过」的第一道闸。
 *
 * 行为对齐 hypium 的部分：
 *  - `describe(name, fn)` 立即执行 fn 以收集用例；
 *  - `it(name, filter, fn)` / `it(name, fn)` 登记一条用例；
 *  - `expect(actual).assertXxx(expected)` 失败时抛错，执行器把错误记为 FAIL（不是吞掉）。
 *
 * 用例登记在 `globalThis.__L1_HYPIUM__` 上，便于执行器与打包后的 bundle 共享同一份登记表。
 */

'use strict';

const REG_KEY = '__L1_HYPIUM__';

function registry() {
  if (!globalThis[REG_KEY]) {
    globalThis[REG_KEY] = { suites: [], cases: [], current: null };
  }
  return globalThis[REG_KEY];
}

function describe(name, fn) {
  const reg = registry();
  const suite = { name: String(name), cases: [] };
  reg.suites.push(suite);
  const prev = reg.current;
  reg.current = suite;
  try {
    fn();
  } finally {
    reg.current = prev;
  }
}

function it(name, filter, fn) {
  const reg = registry();
  const body = typeof filter === 'function' ? filter : fn;
  if (typeof body !== 'function') {
    throw new Error(`hypium 垫片：用例「${name}」没有提供执行体`);
  }
  const suiteName = reg.current === null ? '(无 describe)' : reg.current.name;
  const record = {
    suite: suiteName,
    name: String(name),
    fn: body,
    index: reg.cases.length,
  };
  reg.cases.push(record);
  if (reg.current !== null) {
    reg.current.cases.push(record);
  }
}

function fmt(value) {
  if (typeof value === 'string') {
    return JSON.stringify(value);
  }
  if (typeof value === 'undefined') {
    return 'undefined';
  }
  if (value === null) {
    return 'null';
  }
  if (typeof value === 'object') {
    try {
      return JSON.stringify(value);
    } catch (e) {
      return String(value);
    }
  }
  return `${value}`;
}

function deepEqual(a, b) {
  if (Object.is(a, b)) {
    return true;
  }
  if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null) {
    return false;
  }
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length) {
    return false;
  }
  for (const k of ka) {
    if (!Object.prototype.hasOwnProperty.call(b, k)) {
      return false;
    }
    if (!deepEqual(a[k], b[k])) {
      return false;
    }
  }
  return true;
}

function fail(matcher, message, actual, expected) {
  const err = new Error(
    `expect(${fmt(actual)}).${matcher}(${expected === undefined ? '' : fmt(expected)}) 失败：${message}`
  );
  err.matcher = matcher;
  throw err;
}

const MATCHERS = {
  assertEqual(actual, expected) {
    if (!deepEqual(actual, expected)) {
      fail('assertEqual', `实际 ≠ 期望（实际 ${fmt(actual)}，期望 ${fmt(expected)}）`, actual, expected);
    }
  },
  assertTrue(actual) {
    if (actual !== true) {
      fail('assertTrue', `实际不是 true（实际 ${fmt(actual)}）`, actual);
    }
  },
  assertFalse(actual) {
    if (actual !== false) {
      fail('assertFalse', `实际不是 false（实际 ${fmt(actual)}）`, actual);
    }
  },
  assertNull(actual) {
    if (actual !== null) {
      fail('assertNull', `实际不是 null（实际 ${fmt(actual)}）`, actual);
    }
  },
  assertUndefined(actual) {
    if (typeof actual !== 'undefined') {
      fail('assertUndefined', `实际不是 undefined（实际 ${fmt(actual)}）`, actual);
    }
  },
  assertContain(actual, expected) {
    const text = typeof actual === 'string' ? actual : fmt(actual);
    if (text.indexOf(String(expected)) < 0) {
      fail('assertContain', `实际不含 ${fmt(expected)}（实际 ${fmt(actual)}）`, actual, expected);
    }
  },
  assertInstanceOf(actual, expected) {
    if (!(actual instanceof expected)) {
      fail('assertInstanceOf', `实际不是 ${expected && expected.name} 的实例`, actual);
    }
  },
  assertThrowError(fn, expected) {
    let thrown = null;
    try {
      fn();
    } catch (e) {
      thrown = e;
    }
    if (thrown === null) {
      fail('assertThrowError', '期望抛错，但没有抛', fn);
    }
    if (typeof expected === 'string' && String(thrown.message).indexOf(expected) < 0) {
      fail('assertThrowError', `抛错信息不含 ${fmt(expected)}（实际 ${fmt(thrown.message)}）`, fn, expected);
    }
  },
  assertLarger(actual, expected) {
    if (!(actual > expected)) {
      fail('assertLarger', `实际没有大于期望（实际 ${fmt(actual)}，期望 > ${fmt(expected)}）`, actual, expected);
    }
  },
  assertLess(actual, expected) {
    if (!(actual < expected)) {
      fail('assertLess', `实际没有小于期望（实际 ${fmt(actual)}，期望 < ${fmt(expected)}）`, actual, expected);
    }
  },
};

function expect(actual) {
  return new Proxy(
    {},
    {
      get(_target, prop) {
        if (typeof prop !== 'string') {
          return undefined;
        }
        return (...args) => {
          const impl = MATCHERS[prop];
          if (typeof impl !== 'function') {
            throw new Error(
              `hypium 垫片未实现匹配器 .${prop}()：拒绝静默通过。若仓库真的用到它，请补进 platform/hypium.cjs 并说明语义`
            );
          }
          return impl(actual, ...args);
        };
      },
    }
  );
}

module.exports = { describe, it, expect };
