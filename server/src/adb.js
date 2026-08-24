const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');
const config = require('./config');

let Adb;
try {
  Adb = require('@devicefarmer/adbkit').Adb;
} catch (e) {
  console.error('[adb] @devicefarmer/adbkit 未安装，请先 npm install');
  throw e;
}

const util = Adb.util;
const client = Adb.createClient({ bin: config.ADB_BIN });

let serverStarted = false;

async function ensureServer() {
  if (serverStarted) return true;
  try {
    await client.version();
    serverStarted = true;
    return true;
  } catch (e) {
    try {
      await new Promise((resolve) => {
        const p = spawn(config.ADB_BIN, ['start-server'], { stdio: 'ignore' });
        p.on('close', resolve);
        p.on('error', resolve);
      });
      await client.version();
      serverStarted = true;
      return true;
    } catch (e2) {
      console.warn('[adb] 无法启动/连接 adb 守护进程，请确认已安装 platform-tools 且 adb 在 PATH 中');
      return false;
    }
  }
}

function getDevice(serial) {
  return client.getDevice(serial);
}

async function listDevices() {
  await ensureServer();
  try {
    const devices = await client.listDevices();
    return devices.map((d) => ({ serial: d.id, state: d.type }));
  } catch (e) {
    return [];
  }
}

async function connectDevice(host, port) {
  port = port || 5555;
  await ensureServer();
  try {
    const serial = await client.connect(host, port);
    return { serial, state: 'device' };
  } catch (e) {
    const msg = (e && e.message) || String(e);
    if (/(already|multiple)/i.test(msg)) {
      const serial = `${host}:${port}`;
      const list = await listDevices();
      const found = list.find((d) => d.serial === serial);
      if (found) return { serial, state: found.state };
      return { serial, state: 'device' };
    }
    const err = new Error(msg);
    if (/unauthorized|signature|device offline/i.test(msg)) {
      err.code = 'UNAUTHORIZED';
    }
    throw err;
  }
}

async function disconnectDevice(serial) {
  await ensureServer();
  const [host, port] = serial.split(':');
  try {
    await client.disconnect(host, port ? parseInt(port, 10) : 5555);
    return true;
  } catch (e) {
    return false;
  }
}

async function getProperties(serial) {
  await ensureServer();
  return client.getDevice(serial).getProperties();
}

async function getDeviceInfo(serial) {
  await ensureServer();
  const props = await getProperties(serial);
  let ip = '';
  try {
    ip = await client.getDevice(serial).getDHCPIpAddress();
  } catch (e) {
    ip = '';
  }
  const name = [
    props['ro.product.brand'],
    props['ro.product.model'],
  ]
    .filter(Boolean)
    .join(' ');
  return {
    serial,
    brand: props['ro.product.brand'] || '',
    model: props['ro.product.model'] || '',
    name: name || serial,
    androidVersion: props['ro.build.version.release'] || '',
    sdk: props['ro.build.version.sdk'] || '',
    serialno: props['ro.serialno'] || serial,
    ip,
    manufacturer: props['ro.product.manufacturer'] || '',
    board: props['ro.board.platform'] || '',
  };
}

module.exports = {
  Adb,
  util,
  client,
  ensureServer,
  getDevice,
  listDevices,
  connectDevice,
  disconnectDevice,
  getProperties,
  getDeviceInfo,
};
