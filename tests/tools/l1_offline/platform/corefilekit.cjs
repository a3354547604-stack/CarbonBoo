/**
 * CoreFileKit 垫片 —— `fileIo`（落盘）+ `picker`（占位）。
 *
 * 被测代码里的 `FilesPort` 是「备份 / 导出 / 清空」的唯一落盘口，语义必须与真机一致：
 *  - `accessSync` 返回 **boolean**（本仓库按 boolean 用：`if (!fileIo.accessSync(dir))`）；
 *  - `statSync(...).size` 是字节数，`listFileSync(dir)` 只列**文件名**（不含路径）；
 *  - `openSync` 的 `OpenMode` 位标志与真机一致（`CREATE|TRUNC` 才覆盖写）；
 *  - `readSync(fd, arrayBuffer)` 把内容**写进调用方给的 ArrayBuffer**并返回读到的字节数
 *    （真机是这么设计的，返回新 buffer 的写法会让 `FilesPort.readText` 读到全零）。
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const OpenMode = {
  READ_ONLY: 0o0,
  WRITE_ONLY: 0o1,
  READ_WRITE: 0o2,
  CREATE: 0o100,
  TRUNC: 0o1000,
  APPEND: 0o2000,
  NONBLOCK: 0o4000,
  DIR: 0o200000,
  NOFOLLOW: 0o400000,
  SYNC: 0o4010000,
};

const openFds = new Map();

function flagOf(mode) {
  const flags = mode || 0;
  if ((flags & OpenMode.CREATE) !== 0) {
    if ((flags & OpenMode.TRUNC) !== 0) {
      return 'w+';
    }
    if ((flags & OpenMode.APPEND) !== 0) {
      return 'a+';
    }
    return fs.existsSync ? 'a+' : 'w+';
  }
  if ((flags & OpenMode.TRUNC) !== 0) {
    return 'r+';
  }
  if ((flags & OpenMode.READ_WRITE) === OpenMode.READ_WRITE) {
    return 'r+';
  }
  if ((flags & OpenMode.WRITE_ONLY) !== 0) {
    return 'w';
  }
  return 'r';
}

class File {
  constructor(fd, filePath) {
    this.fd = fd;
    this.path = filePath;
    this.name = path.basename(filePath);
  }

  getParent() {
    return path.dirname(this.path);
  }
}

class Stat {
  constructor(st) {
    this.size = st.size;
    this.mode = st.mode;
    this.mtime = Math.floor(st.mtimeMs / 1000);
    this.ino = String(st.ino);
    this._isDir = st.isDirectory();
  }

  isDirectory() {
    return this._isDir;
  }

  isFile() {
    return !this._isDir;
  }
}

function openSync(filePath, mode) {
  const flags = flagOf(mode);
  const fd = fs.openSync(filePath, flags);
  openFds.set(fd, filePath);
  return new File(fd, filePath);
}

function closeSync(file) {
  const fd = typeof file === 'number' ? file : file.fd;
  if (openFds.has(fd)) {
    fs.closeSync(fd);
    openFds.delete(fd);
  }
}

function writeSync(fd, buffer, options) {
  const target = typeof fd === 'number' ? fd : fd.fd;
  let payload;
  if (typeof buffer === 'string') {
    payload = Buffer.from(buffer, 'utf8');
  } else if (buffer instanceof ArrayBuffer) {
    payload = Buffer.from(new Uint8Array(buffer));
  } else {
    payload = Buffer.from(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  }
  const opts = options || {};
  const position = typeof opts.offset === 'number' ? null : null;
  return fs.writeSync(target, payload, 0, payload.length, position);
}

function readSync(fd, buffer, options) {
  const target = typeof fd === 'number' ? fd : fd.fd;
  const opts = options || {};
  const length = typeof opts.length === 'number' ? opts.length : buffer.byteLength;
  const out = Buffer.alloc(length);
  const read = fs.readSync(target, out, 0, length, null);
  const dest = new Uint8Array(buffer, 0, read);
  dest.set(out.subarray(0, read));
  return read;
}

function accessSync(filePath) {
  try {
    fs.accessSync(filePath);
    return true;
  } catch (e) {
    return false;
  }
}

function statSync(filePath) {
  return new Stat(fs.statSync(filePath));
}

function listFileSync(dir) {
  return fs.readdirSync(dir);
}

function unlinkSync(filePath) {
  fs.unlinkSync(filePath);
}

function mkdirSync(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function copyFileSync(src, dest) {
  fs.copyFileSync(src, dest);
}

function renameSync(src, dest) {
  fs.renameSync(src, dest);
}

module.exports = {
  fileIo: {
    OpenMode,
    openSync,
    closeSync,
    writeSync,
    readSync,
    accessSync,
    statSync,
    listFileSync,
    unlinkSync,
    mkdirSync,
    copyFileSync,
    renameSync,
  },
  picker: {
    DocumentViewPicker: function DocumentViewPicker() {},
    PhotoViewPicker: function PhotoViewPicker() {},
  },
};
