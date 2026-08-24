const express = require('express');
const adb = require('../adb');
const fs = require('fs');
const path = require('path');
const config = require('../config');

const router = express.Router();

async function shell(serial, cmd) {
  return (await adb.util.readAll(await adb.getDevice(serial).shell(cmd))).toString('utf8');
}

async function ping(serial, host) {
  const out = await shell(serial, `ping -c 4 ${host}`);
  const loss = (out.match(/(\d+)% packet loss/) || [])[1];
  const parts = (out.match(/min\/avg\/max\/mdev = ([\d.]+)\/([\d.]+)\/([\d.]+)\//) || []);
  return {
    host,
    loss: loss != null ? parseInt(loss, 10) : 100,
    min: parts[1] ? parseFloat(parts[1]) : null,
    avg: parts[2] ? parseFloat(parts[2]) : null,
    max: parts[3] ? parseFloat(parts[3]) : null,
  };
}

async function throughput(serial) {
  const sizeMB = 5;
  const buf = Buffer.alloc(sizeMB * 1024 * 1024);
  for (let i = 0; i + 4 <= buf.length; i += 4096) {
    buf.writeUInt32LE((Math.random() * 0xffffffff) >>> 0, i);
  }
  const local = path.join(config.UPLOAD_DIR, `spd_${Date.now()}.bin`);
  fs.writeFileSync(local, buf);
  const device = adb.getDevice(serial);
  const remote = `/data/local/tmp/adbweb_spd_${Date.now()}.bin`;
  const t0 = Date.now();
  let tr = await device.push(local, remote);
  await new Promise((res, rej) => { tr.on('end', res); tr.on('error', rej); });
  const pushMs = Date.now() - t0;
  const t1 = Date.now();
  let pull = await device.pull(remote);
  const outLocal = path.join(config.UPLOAD_DIR, `spd_out_${Date.now()}.bin`);
  await new Promise((res, rej) => { pull.on('end', res); pull.on('error', rej); pull.pipe(fs.createWriteStream(outLocal)); });
  const pullMs = Date.now() - t1;
  try { await adb.util.readAll(await device.shell(`rm -f ${remote}`)); } catch (e) {}
  try { fs.unlinkSync(local); fs.unlinkSync(outLocal); } catch (e) {}
  return {
    sizeMB,
    pushMbps: parseFloat((sizeMB / (pushMs / 1000)).toFixed(2)),
    pullMbps: parseFloat((sizeMB / (pullMs / 1000)).toFixed(2)),
    pushMs,
    pullMs,
  };
}

function parseWifi(text) {
  const rx = (text.match(/mRxLinkSpeed[:=]\s*(\d+)/) || [])[1];
  const rssi = (text.match(/mRssi[:=]\s*(-?\d+)/) || [])[1];
  return { rxMbps: rx ? parseInt(rx, 10) : null, rssi: rssi ? parseInt(rssi, 10) : null };
}

router.post('/nettest/:serial', async (req, res) => {
  const serial = req.params.serial;
  const host = (req.body && req.body.host) || '8.8.8.8';
  try {
    const [pingRes, tp, wifi] = await Promise.all([
      ping(serial, host).catch((e) => ({ host, error: e.message })),
      throughput(serial).catch((e) => ({ error: e.message })),
      shell(serial, 'dumpsys wifi').then(parseWifi).catch(() => null),
    ]);
    res.json({ ping: pingRes, throughput: tp, wifi });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
