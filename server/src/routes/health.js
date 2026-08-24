const express = require('express');
const adb = require('../adb');

const router = express.Router();
const lastStat = new Map();

async function shell(serial, cmd) {
  return (await adb.util.readAll(await adb.getDevice(serial).shell(cmd))).toString('utf8');
}

function parseMem(text) {
  const mem = {};
  for (const line of text.split('\n')) {
    const m = line.match(/^(\w+):\s+(\d+)\s*kB/);
    if (m) mem[m[1]] = parseInt(m[2], 10) * 1024;
  }
  const total = mem.MemTotal || 0;
  const available = mem.MemAvailable != null ? mem.MemAvailable : (mem.MemFree || 0);
  const used = total - available;
  return { total, available, used, percent: total ? Math.round((used / total) * 100) : 0 };
}

function parseCpu(text) {
  const cpus = [];
  let total = null;
  for (const line of text.split('\n')) {
    const m = line.match(/^cpu(\d*)\s+(.+)/);
    if (!m) continue;
    const parts = m[2].trim().split(/\s+/).map(Number);
    const idle = parts[3] + parts[4];
    const t = parts.reduce((a, b) => a + b, 0);
    if (m[1] === '') total = { idle, total: t };
    else cpus.push({ core: m[1], idle, total: t });
  }
  return { total, cpus };
}

function computeDelta(prev, cur) {
  if (!prev || cur.total <= prev.total) return 0;
  const dIdle = cur.idle - prev.idle;
  const dTotal = cur.total - prev.total;
  if (dTotal <= 0) return 0;
  return Math.round((1 - dIdle / dTotal) * 100);
}

async function getCpu(serial) {
  let text;
  try { text = await shell(serial, 'cat /proc/stat'); } catch (e) { return null; }
  const cur = parseCpu(text);
  const prev = lastStat.get(serial);
  let result = null;
  if (prev) {
    result = {
      percent: computeDelta(prev.total, cur.total),
      cores: cur.cpus.map((c, i) => ({ core: c.core, percent: computeDelta(prev.cpus[i], c) })),
    };
  }
  lastStat.set(serial, cur);
  return result;
}

async function getStorage(serial) {
  const text = await shell(serial, 'df -P 2>/dev/null');
  const rows = [];
  for (const line of text.split('\n')) {
    const m = line.match(/^(\/\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\S+)/);
    if (!m) continue;
    const mount = m[6];
    if (mount === '/' || mount === '/system' || mount.startsWith('/data') || mount.startsWith('/storage') || mount === '/sdcard') {
      rows.push({
        mount,
        total: parseInt(m[2], 10) * 1024,
        used: parseInt(m[3], 10) * 1024,
        available: parseInt(m[4], 10) * 1024,
        percent: parseInt(m[5], 10),
      });
    }
  }
  return rows;
}

async function getBattery(serial) {
  try {
    const text = await shell(serial, 'dumpsys battery');
    const lvl = (text.match(/level:\s*(\d+)/) || [])[1];
    const temp = (text.match(/temperature:\s*(\d+)/) || [])[1];
    return { level: lvl ? parseInt(lvl, 10) : null, tempC: temp ? parseInt(temp, 10) / 10 : null };
  } catch (e) {
    return { level: null, tempC: null };
  }
}

async function getWifi(serial) {
  try {
    const text = await shell(serial, 'dumpsys wifi');
    const rx = (text.match(/mRxLinkSpeed[:=]\s*(\d+)/) || [])[1];
    const rssi = (text.match(/mRssi[:=]\s*(-?\d+)/) || [])[1];
    const ssid = (text.match(/SSID:\s*([^\n,]+)/) || [])[1];
    return {
      rxMbps: rx ? parseInt(rx, 10) : null,
      rssi: rssi ? parseInt(rssi, 10) : null,
      ssid: (ssid || '').trim(),
    };
  } catch (e) {
    return null;
  }
}

router.get('/health/:serial/snapshot', async (req, res) => {
  const serial = req.params.serial;
  try {
    const [mem, cpu, storage, battery, wifi] = await Promise.all([
      shell(serial, 'cat /proc/meminfo').then(parseMem),
      getCpu(serial),
      getStorage(serial),
      getBattery(serial),
      getWifi(serial),
    ]);
    res.json({ ts: Date.now(), mem, cpu, storage, battery, wifi });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
