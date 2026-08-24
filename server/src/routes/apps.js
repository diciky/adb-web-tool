const express = require('express');
const adb = require('../adb');
const meta = require('../meta');

const router = express.Router();

const SYSTEM_PREFIX = ['/system', '/vendor', '/product', '/odm', '/apex', '/framework', '/system_ext'];

function isSystem(path) {
  return SYSTEM_PREFIX.some((p) => path.startsWith(p));
}

async function listApps(serial) {
  await adb.ensureServer();
  const device = adb.getDevice(serial);
  const out = await adb.util.readAll(await device.shell('pm list packages -f'));
  const text = out.toString('utf8');
  const disabledOut = await adb.util.readAll(await device.shell('pm list packages -d'));
  const disabled = new Set(
    disabledOut
      .toString('utf8')
      .split('\n')
      .map((l) => l.trim())
      .filter(Boolean)
      .map((l) => l.replace(/^package:/, '').trim())
  );

  const apps = [];
  for (const line of text.split('\n')) {
    const m = line.trim().match(/^package:(.*)=(.*)$/);
    if (!m) continue;
    const appPath = m[1];
    const pkg = m[2];
    const cached = meta.peekMeta(serial, appPath);
    apps.push({
      pkg,
      path: appPath,
      type: isSystem(appPath) ? 'system' : 'user',
      disabled: disabled.has(pkg),
      name: (cached && cached.name) || pkg,
      versionName: (cached && cached.versionName) || '',
      versionCode: (cached && cached.versionCode) || '',
      iconUrl: (cached && cached.iconUrl) || null,
      metaCached: !!cached,
    });
  }

  // 回填版本号：一次 dumpsys package 批量获取全部版本（不打 APK）。
  // 已缓存的应用版本写入缓存文件；未缓存的也先挂上版本号，名称/图标等识别时补全。
  if (apps.some((a) => !a.versionName)) {
    const vmap = await meta.getVersionsBatch(serial);
    for (const a of apps) {
      const v = vmap[a.pkg];
      if (!v || (!v.versionName && !v.versionCode)) continue;
      if (a.metaCached) {
        const updated = meta.fillCachedVersion(serial, a.path, v);
        if (updated) {
          a.versionName = updated.versionName || '';
          a.versionCode = updated.versionCode || '';
        }
      } else {
        a.versionName = v.versionName || '';
        a.versionCode = v.versionCode || '';
      }
    }
  }

  return apps;
}

router.get('/apps/:serial', async (req, res) => {
  try {
    const apps = await listApps(req.params.serial);
    res.json(apps);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/apps/:serial/meta', async (req, res) => {
  const { pkg, path } = req.body || {};
  if (!pkg || !path) return res.status(400).json({ error: '缺少 pkg 或 path' });
  try {
    const m = await meta.getMeta(req.params.serial, pkg, path);
    res.json(m);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/uninstall/:serial', async (req, res) => {
  const { pkg } = req.body || {};
  if (!pkg) return res.status(400).json({ error: '缺少 pkg' });
  try {
    const device = adb.getDevice(req.params.serial);
    let out = await adb.util.readAll(await device.shell(`pm uninstall ${pkg}`));
    let result = out.toString('utf8');
    if (!/Success/i.test(result)) {
      out = await adb.util.readAll(await device.shell(`pm uninstall --user 0 ${pkg}`));
      result = out.toString('utf8');
    }
    const ok = /Success/i.test(result);
    res.json({ ok, message: result.trim() });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/apps/:serial/launch', async (req, res) => {
  const { pkg } = req.body || {};
  if (!pkg) return res.status(400).json({ error: '缺少 pkg' });
  try {
    const device = adb.getDevice(req.params.serial);
    const out = await adb.util.readAll(
      await device.shell(`monkey -p ${pkg} -c android.intent.category.LAUNCHER 1`)
    );
    res.json({ ok: true, message: out.toString('utf8').trim() });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/apps/:serial/clear', async (req, res) => {
  const { pkg } = req.body || {};
  if (!pkg) return res.status(400).json({ error: '缺少 pkg' });
  try {
    await adb.getDevice(req.params.serial).clear(pkg);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/apps/:serial/force-stop', async (req, res) => {
  const { pkg } = req.body || {};
  if (!pkg) return res.status(400).json({ error: '缺少 pkg' });
  try {
    await adb.util.readAll(await adb.getDevice(req.params.serial).shell(`am force-stop ${pkg}`));
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.get('/apps/:serial/export/:pkg', async (req, res) => {
  const apkPath = req.query.path;
  if (!apkPath) return res.status(400).json({ error: '缺少 path' });
  try {
    const transfer = await adb.getDevice(req.params.serial).pull(apkPath);
    res.setHeader('Content-Type', 'application/vnd.android.package-archive');
    res.setHeader('Content-Disposition', `attachment; filename="${req.params.pkg}.apk"`);
    transfer.on('error', (e) => {
      if (!res.headersSent) res.status(500).json({ error: e.message });
    });
    transfer.pipe(res);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
