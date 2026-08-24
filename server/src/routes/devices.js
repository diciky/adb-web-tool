const express = require('express');
const scanner = require('../scanner');
const adb = require('../adb');

const router = express.Router();

router.get('/subnets', (req, res) => {
  res.json(scanner.detectSubnets());
});

router.post('/scan', async (req, res) => {
  const subnet = req.body && req.body.subnet;
  const bus = require('../ws').bus;
  res.json({ started: true, subnet: subnet || 'auto' });
  scanner.startScan(subnet, bus).catch((e) => {
    bus.emit('scan_done', { subnet: subnet || '', total: 0, error: e.message });
  });
});

router.get('/devices', async (req, res) => {
  const devices = await adb.listDevices();
  res.json(devices);
});

router.post('/connect', async (req, res) => {
  const { host, port } = req.body || {};
  if (!host) return res.status(400).json({ error: '缺少 host' });
  try {
    const r = await adb.connectDevice(host, parseInt(port || '5555', 10));
    res.json(r);
  } catch (e) {
    if (e.code === 'UNAUTHORIZED') {
      return res.status(202).json({ ok: false, code: 'UNAUTHORIZED', message: '请在电视上确认「USB 调试授权」提示后再连接' });
    }
    res.status(500).json({ error: e.message });
  }
});

router.post('/disconnect', async (req, res) => {
  const { serial } = req.body || {};
  if (!serial) return res.status(400).json({ error: '缺少 serial' });
  const ok = await adb.disconnectDevice(serial);
  res.json({ ok });
});

router.get('/device/:serial/info', async (req, res) => {
  try {
    const info = await adb.getDeviceInfo(req.params.serial);
    res.json(info);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
