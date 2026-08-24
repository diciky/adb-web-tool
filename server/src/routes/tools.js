const express = require('express');
const adb = require('../adb');

const router = express.Router();

router.get('/tools/:serial/screenshot', async (req, res) => {
  const serial = req.params.serial;
  try {
    const stream = await adb.getDevice(serial).screencap();
    res.setHeader('Content-Type', 'image/png');
    stream.on('error', (e) => {
      if (!res.headersSent) res.status(500).json({ error: e.message });
    });
    stream.pipe(res);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/tools/:serial/key', async (req, res) => {
  const serial = req.params.serial;
  const { code } = req.body || {};
  if (code === undefined || code === null) return res.status(400).json({ error: '缺少 code' });
  try {
    await adb.util.readAll(await adb.getDevice(serial).shell(`input keyevent ${parseInt(code, 10)}`));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/tools/:serial/text', async (req, res) => {
  const serial = req.params.serial;
  const { text } = req.body || {};
  if (!text) return res.status(400).json({ error: '缺少 text' });
  try {
    const escaped = text.replace(/'/g, "").replace(/ /g, '%s');
    await adb.util.readAll(await adb.getDevice(serial).shell(`input text '${escaped}'`));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/tools/:serial/power', async (req, res) => {
  const serial = req.params.serial;
  const { action } = req.body || {};
  try {
    const device = adb.getDevice(serial);
    if (action === 'recovery') {
      await device.reboot('recovery');
    } else if (action === 'bootloader') {
      await device.reboot('bootloader');
    } else if (action === 'shutdown') {
      await adb.util.readAll(await device.shell('reboot -p'));
    } else {
      await device.reboot();
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/tools/:serial/wake', async (req, res) => {
  const serial = req.params.serial;
  const { action } = req.body || {};
  try {
    const code = action === 'sleep' ? 223 : 224;
    await adb.util.readAll(await adb.getDevice(serial).shell(`input keyevent ${code}`));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

async function shell(serial, cmd) {
  return (await adb.util.readAll(await adb.getDevice(serial).shell(cmd))).toString('utf8');
}

const CLIPPERS = ['org.albireo.clipper'];

router.post('/tools/:serial/clipboard', async (req, res) => {
  const serial = req.params.serial;
  const { text, paste } = req.body || {};
  if (!text) return res.status(400).json({ error: '缺少 text' });
  let method = 'none';
  try {
    const pkgs = await shell(serial, 'pm list packages');
    const helper = CLIPPERS.find((c) => pkgs.includes(c));
    if (helper) {
      const escaped = text.replace(/"/g, '\\"');
      await shell(serial, `am broadcast -a ${helper}.set -e text "${escaped}"`);
      method = 'clipper:' + helper;
    } else {
      try {
        await shell(serial, `service call clipboard 2 i32 1 s16 "${text.replace(/"/g, '\\"')}"`);
        method = 'service_call';
      } catch (e) {
        if (/^[\x00-\x7F]*$/.test(text)) {
          await shell(serial, `input text '${text.replace(/ /g, '%s')}'`);
          method = 'input_text';
        } else {
          return res.status(501).json({
            error: '未安装剪贴板助手（如 Clipper）且系统不支持 service call，无法输入中文。请在电视上安装 Clipper 应用后再试。',
          });
        }
      }
    }
    if (paste) await shell(serial, 'input keyevent 279');
    res.json({ ok: true, method });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
