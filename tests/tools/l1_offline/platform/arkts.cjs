/**
 * ArkTS 基础库垫片 —— `@kit.ArkTS` 的 `util`。
 *
 * 被测代码只用到 `util.TextDecoder`（4 处：读 rawfile → 字符串），但 `decodeToString` 的入参既可能是
 * `Uint8Array` 也可能是 `ArrayBuffer`（真实 SDK 两者都收），所以两个分支都要覆盖 —— 少写一个分支
 * 会让「读基准」这一步静默拿到乱码，进而把整条离线链路变成假红/假绿。
 */

'use strict';

class TextDecoder {
  constructor(encoding, options) {
    this._encoding = encoding || 'utf-8';
    this._options = options || {};
  }

  decodeToString(input) {
    const buf = input instanceof ArrayBuffer
      ? Buffer.from(new Uint8Array(input))
      : Buffer.from(input.buffer, input.byteOffset, input.byteLength);
    return buf.toString('utf8');
  }

  decodeWithStream(input, options) {
    return this.decodeToString(input);
  }
}

class TextEncoder {
  constructor(encoding) {
    this._encoding = encoding || 'utf-8';
  }

  encodeInto(input) {
    const buf = Buffer.from(String(input), 'utf8');
    const out = new Uint8Array(buf.length);
    out.set(buf);
    return out;
  }

  encodeIntoUint8Array(input, dest) {
    const buf = Buffer.from(String(input), 'utf8');
    const n = Math.min(buf.length, dest.length);
    dest.set(buf.subarray(0, n));
    return { read: n, written: n };
  }
}

class Base64Helper {
  encodeToStringSync(input) {
    const buf = input instanceof ArrayBuffer
      ? Buffer.from(new Uint8Array(input))
      : Buffer.from(input.buffer, input.byteOffset, input.byteLength);
    return buf.toString('base64');
  }

  decodeSync(input) {
    const buf = Buffer.from(String(input), 'base64');
    const out = new Uint8Array(buf.length);
    out.set(buf);
    return out;
  }
}

let uuidCounter = 0;

const util = {
  TextDecoder,
  TextEncoder,
  Base64Helper,
  /** 真机是 v4 UUID；离线执行只要「每次不同且形似 UUID」即可，用于记录 ID 之类的占位。 */
  generateRandomUUID(entropyCache) {
    uuidCounter += 1;
    const hex = `${Date.now().toString(16)}${process.pid.toString(16)}${uuidCounter.toString(16).padStart(4, '0')}`;
    const padded = (hex + '0'.repeat(32)).slice(0, 32);
    return `${padded.slice(0, 8)}-${padded.slice(8, 12)}-4${padded.slice(13, 16)}-8${padded.slice(17, 20)}-${padded.slice(20, 32)}`;
  },
};

module.exports = { util };
