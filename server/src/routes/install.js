const express = require('express');
const fs = require('fs');
const path = require('path');
const multer = require('multer');
const adb = require('../adb');
const config = require('../config');
const bus = require('../ws').bus;

const router = express.Router();

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, config.UPLOAD_DIR),
  filename: (req, file, cb) => {
    const safe = file.originalname.replace(/[^\w.\-]+/g, '_');
    cb(null, `${Date.now()}_${Math.random().toString(36).slice(2)}_${safe}`);
  },
});
const upload = multer({ storage, limits: { fileSize: config.UPLOAD_MAX_MB * 1024 * 1024 } }).single('apk');

router.post('/install/:serial', (req, res) => {
  upload(req, res, async (err) => {
    if (err) return res.status(400).json({ error: err.message });
    if (!req.file) return res.status(400).json({ error: '未收到 apk 文件' });
    const serial = req.params.serial;
    const jobId = req.body.jobId || `install_${Date.now()}`;
    const local = req.file.path;
    const remote = `/data/local/tmp/adbweb_${Date.now()}_${path.basename(local)}`;

    const emit = (extra) => bus.emit('task', { id: jobId, kind: 'install', serial, ...extra });

    try {
      const device = adb.getDevice(serial);
      const transfer = await device.push(local, remote);
      transfer.on('progress', (stats) => {
        const pct = stats.bytesTotal
          ? Math.round((stats.bytesTransferred / stats.bytesTotal) * 100)
          : 0;
        emit({ phase: 'push', percent: Math.min(99, pct), message: `上传 ${pct}%` });
      });
      await new Promise((resolve, reject) => {
        transfer.on('end', resolve);
        transfer.on('error', reject);
      });
      emit({ phase: 'install', percent: 99, message: '正在安装...' });
      await device.installRemote(remote);
      emit({ phase: 'done', percent: 100, done: true, message: '安装完成' });
      res.json({ ok: true, jobId });
    } catch (e) {
      emit({ phase: 'error', error: e.message, done: true });
      res.status(500).json({ error: e.message });
    } finally {
      try { fs.unlinkSync(local); } catch (e) {}
    }
  });
});

module.exports = router;
