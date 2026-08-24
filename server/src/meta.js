const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const adb = require('./adb');
const config = require('./config');

let AppInfoParser;
try {
  AppInfoParser = require('app-info-parser');
} catch (e) {
  AppInfoParser = null;
}

function md5(str) {
  return crypto.createHash('md5').update(String(str)).digest('hex');
}

async function pullApk(serial, apkPath) {
  await adb.ensureServer();
  const tmp = path.join(config.UPLOAD_DIR, `meta_${crypto.randomBytes(6).toString('hex')}.apk`);
  const transfer = await adb.getDevice(serial).pull(apkPath);
  let size = 0;
  const out = fs.createWriteStream(tmp);
  await new Promise((resolve, reject) => {
    transfer.on('progress', (stats) => {
      size = stats.bytesTransferred;
      if (size > config.PULL_MAX_BYTES) {
        transfer.end();
        reject(new Error('APK_SIZE_EXCEED'));
      }
    });
    transfer.on('error', reject);
    transfer.on('end', resolve);
    transfer.pipe(out);
  });
  return tmp;
}

async function parseIcon(icon, key) {
  const pngPath = path.join(config.CACHE_DIR, `${key}.png`);
  let buf = null;
  if (Buffer.isBuffer(icon)) {
    buf = icon;
  } else if (typeof icon === 'string') {
    if (/^[A-Za-z0-9+/=]+$/.test(icon) && icon.length > 100) {
      try { buf = Buffer.from(icon, 'base64'); } catch (e) {}
    }
  } else if (icon && icon.data) {
    buf = Buffer.isBuffer(icon.data) ? icon.data : Buffer.from(icon.data);
  }
  if (buf && buf.length > 4 && buf[0] === 0x89 && buf[1] === 0x50) {
    fs.writeFileSync(pngPath, buf);
    return `/cache/${key}.png`;
  }
  return null;
}

async function getMeta(serial, pkg, apkPath) {
  await adb.ensureServer();
  if (!AppInfoParser) {
    return { name: pkg, versionName: '', versionCode: '', iconUrl: null, cached: false };
  }
  const key = md5(`${serial}|${apkPath}`);

  const jsonPath = path.join(config.CACHE_DIR, `${key}.json`);
  if (fs.existsSync(jsonPath)) {
    try {
      const cached = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
      cached.cached = true;
      return cached;
    } catch (e) {}
  }

  let tmp;
  try {
    tmp = await pullApk(serial, apkPath);
  } catch (e) {
    if (e.message === 'APK_SIZE_EXCEED') {
      const fallback = { name: pkg, versionName: '', versionCode: '', iconUrl: null, cached: false };
      fs.writeFileSync(jsonPath, JSON.stringify(fallback));
      return fallback;
    }
    throw e;
  }

  try {
    const parser = new AppInfoParser(tmp);
    const result = await parser.parse();
    const app = result.application || {};
    let label = app.label;
    if (label && typeof label === 'object') {
      label = label.value || label.text || Object.values(label)[0];
    }
    // 修复 UTF-16LE 宽字符标签被按单字节解码后每个字符间出现的空字节（如 "U\u0000p\u0000g"）
    if (typeof label === 'string' && label.indexOf('\u0000') !== -1) {
      try { label = Buffer.from(label, 'latin1').toString('utf16le'); } catch (e) {}
    }
    const iconUrl = await parseIcon(app.icon, key);
    const meta = {
      name: label && String(label).trim() ? String(label).trim() : pkg,
      versionName: app.versionName || '',
      versionCode: app.versionCode || '',
      iconUrl,
      cached: false,
    };
    fs.writeFileSync(jsonPath, JSON.stringify(meta));
    return meta;
  } finally {
    try { fs.unlinkSync(tmp); } catch (e) {}
  }
}

// 仅读取已缓存的元数据（不触发 APK 拉取），用于列表接口直接挂上名称/图标
function peekMeta(serial, apkPath) {
  const key = md5(`${serial}|${apkPath}`);
  const jsonPath = path.join(config.CACHE_DIR, `${key}.json`);
  if (fs.existsSync(jsonPath)) {
    try {
      return JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    } catch (e) {}
  }
  return null;
}

module.exports = { getMeta, peekMeta };
