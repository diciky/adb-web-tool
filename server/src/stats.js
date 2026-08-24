const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const adb = require('./adb');
const config = require('./config');

function md5(s) {
  return crypto.createHash('md5').update(String(s)).digest('hex');
}

function cacheGet(file, maxAgeMs) {
  try {
    if (fs.existsSync(file)) {
      const o = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (o && o.savedAt && Date.now() - o.savedAt < maxAgeMs) return o;
    }
  } catch (e) {}
  return null;
}

function cacheSet(file, obj) {
  try {
    fs.writeFileSync(file, JSON.stringify({ savedAt: Date.now(), ...obj }));
  } catch (e) {}
}

// 解析 dumpsys diskstats 输出：每应用 大小/数据/缓存 + 设备总量（数组按包名一一对应）
function parseDiskStats(text) {
  const grab = (key) => {
    const m = text.match(new RegExp('^' + key + ': (\\[.*\\])', 'm'));
    if (!m) return null;
    try { return JSON.parse(m[1]); } catch (e) { return null; }
  };
  const pkgs = grab('Package Names');
  const sizes = grab('App Sizes');
  const dataSizes = grab('App Data Sizes');
  const cacheSizes = grab('Cache Sizes');
  const map = {};
  if (Array.isArray(pkgs) && pkgs.length) {
    const n = Math.min(
      pkgs.length,
      sizes ? sizes.length : 0,
      dataSizes ? dataSizes.length : 0,
      cacheSizes ? cacheSizes.length : 0
    );
    for (let i = 0; i < n; i++) {
      map[pkgs[i]] = {
        size: sizes[i] || 0,
        dataSize: dataSizes[i] || 0,
        cacheSize: cacheSizes[i] || 0,
      };
    }
  }
  const num = (key) => {
    const m = text.match(new RegExp('^' + key + ': (\\d+)', 'm'));
    return m ? parseInt(m[1], 10) : 0;
  };
  const freeMatch = text.match(/^Data-Free: ([\d.]+)K \/ ([\d.]+)K total/m);
  const totals = {
    appSize: num('App Size'),
    appDataSize: num('App Data Size'),
    appCacheSize: num('App Cache Size'),
    dataFreeK: freeMatch ? Math.round(parseFloat(freeMatch[1])) : 0,
    dataTotalK: freeMatch ? Math.round(parseFloat(freeMatch[2])) : 0,
  };
  return { map, totals };
}

// 每应用 大小/数据/缓存 映射（按设备缓存 6h，大小不常变）
async function getDiskStats(serial) {
  const file = path.join(config.CACHE_DIR, `_diskstats_${md5(serial)}.json`);
  const cached = cacheGet(file, 6 * 60 * 60 * 1000);
  if (cached && cached.map) return cached;
  let result = { map: {}, totals: {} };
  try {
    await adb.ensureServer();
    const out = await adb.util.readAll(await adb.getDevice(serial).shell('dumpsys diskstats'));
    result = parseDiskStats(out.toString('utf8'));
  } catch (e) {}
  cacheSet(file, result);
  return result;
}

// 运行中的应用包名（ps -A，按设备缓存 10s；进程名带 :xxx 后缀的归到主包名）
async function getRunningBaseSet(serial) {
  const file = path.join(config.CACHE_DIR, `_running_${md5(serial)}.json`);
  const cached = cacheGet(file, 10 * 1000);
  if (cached && cached.packages) return new Set(cached.packages);
  const set = new Set();
  try {
    await adb.ensureServer();
    const out = await adb.util.readAll(await adb.getDevice(serial).shell('ps -A'));
    for (const line of out.toString('utf8').split('\n')) {
      const fields = line.trim().split(/\s+/);
      if (fields.length < 2) continue;
      const name = fields[fields.length - 1];
      if (!name || name === 'NAME' || name.startsWith('[')) continue;
      set.add(name.split(':')[0]);
    }
  } catch (e) {}
  cacheSet(file, { packages: [...set] });
  return set;
}

module.exports = { getDiskStats, getRunningBaseSet };
