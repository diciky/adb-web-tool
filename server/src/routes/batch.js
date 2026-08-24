const express = require('express');
const multer = require('multer');
const fs = require('fs');
const path = require('path');
const config = require('../config');
const { executeAction } = require('../actions');
const scheduler = require('../scheduler');

const router = express.Router();

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, config.UPLOAD_DIR),
  filename: (req, file, cb) => cb(null, `${Date.now()}_${Math.random().toString(36).slice(2)}_${file.originalname.replace(/[^\w.\-]+/g, '_')}`),
});
const upload = multer({ storage, limits: { fileSize: config.UPLOAD_MAX_MB * 1024 * 1024 } }).single('file');

router.post('/shared-upload', (req, res) => {
  upload(req, res, () => {
    if (!req.file) return res.status(400).json({ error: '未收到文件' });
    res.json({ path: req.file.path, name: req.file.originalname });
  });
});

router.post('/batch/run', async (req, res) => {
  const { action, targets, params } = req.body || {};
  if (!action || !Array.isArray(targets)) return res.status(400).json({ error: '缺少 action 或 targets' });
  const results = [];
  for (const serial of targets) {
    const r = await executeAction(serial, action, params || {});
    results.push({ serial, ...r });
  }
  res.json({ results });
});

router.get('/schedules', (req, res) => res.json(scheduler.list()));
router.post('/schedules', (req, res) => {
  const job = req.body || {};
  if (!job.action || !Array.isArray(job.targets)) return res.status(400).json({ error: '缺少 action / targets' });
  const created = scheduler.addJob(job);
  res.json(created);
});
router.delete('/schedules/:id', (req, res) => {
  scheduler.removeJob(req.params.id);
  res.json({ ok: true });
});
router.post('/schedules/:id/run', async (req, res) => {
  try {
    const job = await scheduler.runNow(req.params.id);
    res.json(job);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
