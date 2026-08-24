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
    // app-info-parser 常取不到版本号，用 dumpsys 直读已装应用版本兜底
    let versionName = app.versionName || '';
    let versionCode = app.versionCode || '';
    if (!versionName && !versionCode) {
      const v = await getVersion(serial, pkg);
      versionName = v.versionName;
      versionCode = v.versionCode;
    }
    const meta = {
      name: label && String(label).trim() ? String(label).trim() : pkg,
      versionName,
      versionCode,
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

// 从 dumpsys package 批量解析所有已装应用版本（一次 shell 调用，不打 APK）
async function getVersionsBatch(serial) {
  try {
    await adb.ensureServer();
    const out = await adb.util.readAll(await adb.getDevice(serial).shell('dumpsys package'));
    const lines = out.toString('utf8').split('\n');
    const map = {};
    let cur = null;
    for (const line of lines) {
      const pm = line.match(/^\s*Package \[([^\]]+)\]/);
      if (pm) {
        cur = pm[1];
        map[cur] = map[cur] || { versionName: '', versionCode: '' };
        continue;
      }
      if (!cur) continue;
      const vn = line.match(/versionName=(\S+)/);
      if (vn && !map[cur].versionName) map[cur].versionName = vn[1];
      const vc = line.match(/versionCode=(\d+)/);
      if (vc && !map[cur].versionCode) map[cur].versionCode = vc[1];
    }
    return map;
  } catch (e) {
    return {};
  }
}

// 单个应用版本（dumpsys 直读，不打 APK）；app-info-parser 拿不到版本号时的可靠来源
async function getVersion(serial, pkg) {
  try {
    await adb.ensureServer();
    const out = await adb.util.readAll(await adb.getDevice(serial).shell(`dumpsys package ${pkg}`));
    const text = out.toString('utf8');
    const vn = text.match(/versionName=(\S+)/);
    const vc = text.match(/versionCode=(\d+)/);
    return { versionName: vn ? vn[1] : '', versionCode: vc ? vc[1] : '' };
  } catch (e) {
    return { versionName: '', versionCode: '' };
  }
}

// 每设备版本映射缓存文件（避免每次加载列表都跑一次 dumpsys package 的 1-6s 延迟）
function versionsCacheFile(serial) {
  return path.join(config.CACHE_DIR, `_versions_${md5(serial)}.json`);
}

// 获取每设备全部应用版本映射：优先读缓存，过期/缺失才重新 dumpsys（默认 12 小时 TTL）
async function getVersionsMap(serial, maxAgeMs) {
  maxAgeMs = maxAgeMs || 12 * 60 * 60 * 1000;
  const f = versionsCacheFile(serial);
  try {
    if (fs.existsSync(f)) {
      const o = JSON.parse(fs.readFileSync(f, 'utf8'));
      if (o && o.savedAt && Date.now() - o.savedAt < maxAgeMs && o.map) return o.map;
    }
  } catch (e) {}
  const map = await getVersionsBatch(serial);
  try {
    fs.writeFileSync(f, JSON.stringify({ savedAt: Date.now(), map }));
  } catch (e) {}
  return map;
}

// 回填已有缓存文件的版本字段（无缓存文件则不动，返回 null）
function fillCachedVersion(serial, apkPath, v) {
  const key = md5(`${serial}|${apkPath}`);
  const jsonPath = path.join(config.CACHE_DIR, `${key}.json`);
  if (!fs.existsSync(jsonPath)) return null;
  try {
    const o = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    if (v && v.versionName) o.versionName = v.versionName;
    if (v && v.versionCode) o.versionCode = v.versionCode;
    fs.writeFileSync(jsonPath, JSON.stringify(o));
    return o;
  } catch (e) {
    return null;
  }
}

module.exports = { getMeta, peekMeta, getVersionsBatch, getVersionsMap, fillCachedVersion };
