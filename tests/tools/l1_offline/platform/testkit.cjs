/**
 * TestKit 垫片 —— `abilityDelegatorRegistry`。
 *
 * 真机上 `getAbilityDelegator().getAppContext()` 返回的是**被测 App 的**上下文；离线执行时
 * 由 `platform/abilitykit.cjs` 提供一个等价对象（目录 + resourceManager）。
 *
 * 注意（如实登记）：真机的 app 上下文只能解析 **app 侧** rawfile，而 `CalcSamples.test.ets:40`
 * 读的 `carbon-calc.json` 只存在于 **ohosTest 侧** rawfile。也就是说这条用例在真机上会因
 * `9001005 not found` 失败。垫片为了把逻辑跑到，把两棵树都挂上了 —— 这是**垫片的便利，不是真机行为**，
 * 已在 `docs/VERIFICATION.md §R9` 的缺口清单里写明。
 */

'use strict';

const { context } = require('./abilitykit.cjs');

const abilityDelegatorRegistry = {
  getAbilityDelegator() {
    return {
      getAppContext() {
        return context;
      },
      getArguments() {
        return {};
      },
      async startAbility() {
        throw new Error('离线执行不支持 startAbility');
      },
    };
  },
  getArguments() {
    return {};
  },
};

module.exports = { abilityDelegatorRegistry };
