const express = require('express');
const adb = require('../adb');
const config = require('../config');

const router = express.Router();
const recordSessions = new Map();

async function shell(serial, cmd) {
  return (await adb.util.readAll(await adb.getDevice(serial).shell(cmd))).toString('utf8');
}

router.get('/tools/:serial/mirror', async (req, res) => {
  const serial = req.params.serial;
  const interval = Math.max(200, parseInt(req.query.interval || '1000', 10));
  res.setHeader('Content-Type', 'multipart/x-mixed-replace; boundary=frame');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  let active = true;
  req.on('close', () => { active = false; });
  const loop = async () => {
    while (active) {
      try {
        const stream = await adb.getDevice(serial).screencap();
        const chunks = [];
        await new Promise((resolve) => {
          stream.on('data', (c) => chunks.push(c));
          stream.on('end', resolve);
          stream.on('error', () => resolve());
        });
        if (!active) break;
        const buf = Buffer.concat(chunks);
        if (buf.length) {
          res.write('--frame\r\n');
          res.write('Content-Type: image/png\r\n');
          res.write('Content-Length: ' + buf.length + '\r\n\r\n');
          res.write(buf);
          res.write('\r\n');
        }
      } catch (e) {
        // 抓取失败则跳过本帧
      }
      await new Promise((r) => setTimeout(r, interval));
    }
  };
  loop();
});

router.post('/tools/:serial/record/start', async (req, res) => {
  const serial = req.params.serial;
  if (recordSessions.has(serial)) return res.status(400).json({ error: '已在录制' });
  const limit = Math.min(180, Math.max(1, parseInt((req.body && req.body.limit) || '60', 10)));
  const file = `/sdcard/adbweb_rec_${Date.now()}.mp4`;
  try {
    const stream = await adb.getDevice(serial).shell(`screenrecord --time-limit ${limit} ${file}`);
    recordSessions.set(serial, { stream, file });
    res.json({ ok: true, file });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/tools/:serial/record/stop', async (req, res) => {
  const serial = req.params.serial;
  const s = recordSessions.get(serial);
  if (!s) return res.status(400).json({ error: '未录制' });
  try { s.stream.end(); } catch (e) {}
  recordSessions.delete(serial);
  res.json({ ok: true, file: s.file });
});

module.exports = router;
