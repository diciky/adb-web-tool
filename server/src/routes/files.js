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
const upload = multer({ storage, limits: { fileSize: config.UPLOAD_MAX_MB * 1024 * 1024 } }).single('file');

router.get('/files/:serial/list', async (req, res) => {
  const serial = req.params.serial;
  const dir = req.query.path || '/sdcard';
  try {
    const files = await adb.getDevice(serial).readdir(dir);
    const list = files.map((f) => ({
      name: f.name,
      isDir: f.isDirectory(),
      size: f.size,
      mtime: f.mtime ? new Date(f.mtime).getTime() : 0,
      mode: f.mode,
    }));
    list.sort((a, b) => (b.isDir - a.isDir) || a.name.localeCompare(b.name));
    res.json({ dir, list });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/files/:serial/upload', (req, res) => {
  upload(req, res, async (err) => {
    if (err) return res.status(400).json({ error: err.message });
    if (!req.file) return res.status(400).json({ error: '未收到文件' });
    const serial = req.params.serial;
    const dir = req.body.path || '/sdcard';
    const jobId = req.body.jobId || `push_${Date.now()}`;
    const local = req.file.path;
    const remote = `${dir.replace(/\/$/, '')}/${req.file.originalname}`;

    const emit = (extra) => bus.emit('task', { id: jobId, kind: 'push', serial, ...extra });

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
      emit({ phase: 'done', percent: 100, done: true, message: '上传完成' });
      res.json({ ok: true, jobId, remote });
    } catch (e) {
      emit({ phase: 'error', error: e.message, done: true });
      res.status(500).json({ error: e.message });
    } finally {
      try { fs.unlinkSync(local); } catch (e) {}
    }
  });
});

router.get('/files/:serial/download', async (req, res) => {
  const serial = req.params.serial;
  const filePath = req.query.path;
  if (!filePath) return res.status(400).json({ error: '缺少 path' });
  try {
    let size = 0;
    try {
      const stat = await adb.getDevice(serial).stat(filePath);
      size = stat.size;
    } catch (e) {}
    const transfer = await adb.getDevice(serial).pull(filePath);
    res.setHeader('Content-Disposition', `attachment; filename="${path.basename(filePath)}"`);
    if (size) res.setHeader('Content-Length', size);
    transfer.on('error', (e) => {
      if (!res.headersSent) res.status(500).json({ error: e.message });
    });
    transfer.pipe(res);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/files/:serial/delete', async (req, res) => {
  const serial = req.params.serial;
  const { path: filePath, recursive } = req.body || {};
  if (!filePath) return res.status(400).json({ error: '缺少 path' });
  try {
    const cmd = recursive ? `rm -rf "${filePath}"` : `rm -f "${filePath}"`;
    await adb.util.readAll(await adb.getDevice(serial).shell(cmd));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/files/:serial/mkdir', async (req, res) => {
  const serial = req.params.serial;
  const { path: dirPath } = req.body || {};
  if (!dirPath) return res.status(400).json({ error: '缺少 path' });
  try {
    await adb.util.readAll(await adb.getDevice(serial).shell(`mkdir -p "${dirPath}"`));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
