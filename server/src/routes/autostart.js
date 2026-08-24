const express = require('express');
const adb = require('../adb');

const router = express.Router();
const cache = new Map();

async function shell(serial, cmd) {
  return (await adb.util.readAll(await adb.getDevice(serial).shell(cmd))).toString('utf8');
}

function parseBootReceivers(dump, pkg) {
  const hasBootPerm = /android\.permission\.RECEIVE_BOOT_COMPLETED:\s*granted=true/.test(dump);
  const components = [];
  const lines = dump.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (!/android\.intent\.action\.BOOT_COMPLETED/.test(lines[i])) continue;
    const window = lines.slice(Math.max(0, i - 4), i + 4).join('\n');
    const comp = window.match(/([a-zA-Z0-9_.-]+\/[\w.\-]+)/);
    if (comp) {
      let compStr = comp[1];
      const seg = compStr.split('/');
      if (seg[0] !== pkg && seg[1] && !seg[1].includes('.')) compStr = `${pkg}/${seg[1]}`;
      const enabled = !/enabled=false/.test(window);
      components.push({ component: compStr, enabled });
    }
  }
  const seen = new Set();
  const uniq = components.filter((c) => {
    if (seen.has(c.component)) return false;
    seen.add(c.component);
    return true;
  });
  return { hasBootPerm, components: uniq };
}

router.get('/autostart/:serial', async (req, res) => {
  const serial = req.params.serial;
  const c = cache.get(serial);
  if (c && Date.now() - c.t < 30000) return res.json(c.v);
  try {
    const out = await shell(serial, 'pm list packages -f');
    const apps = [];
    for (const line of out.split('\n')) {
      const m = line.trim().match(/^package:(.*)=(.*)$/);
      if (m && m[1].startsWith('/data')) apps.push({ pkg: m[2], path: m[1] });
    }
    const result = [];
    for (const a of apps.slice(0, 300)) {
      const dump = await shell(serial, `dumpsys package ${a.pkg}`);
      const { hasBootPerm, components } = parseBootReceivers(dump, a.pkg);
      if (hasBootPerm || components.length) {
        result.push({
          pkg: a.pkg,
          bootEnabled: components.length ? components.some((c) => c.enabled) : null,
          hasBootPerm,
          components,
        });
      }
    }
    cache.set(serial, { t: Date.now(), v: result });
    res.json(result);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

router.post('/autostart/:serial/toggle', async (req, res) => {
  const serial = req.params.serial;
  const { component, enabled } = req.body || {};
  if (!component) return res.status(400).json({ error: '缺少 component' });
  const isPkg = !component.includes('/');
  const cmd = enabled
    ? isPkg ? `pm enable ${component}` : `pm enable ${component}`
    : isPkg ? `pm disable ${component}` : `pm disable ${component}`;
  try {
    const out = await shell(serial, cmd);
    cache.delete(serial);
    res.json({ ok: /enabled|disabled|new state/i.test(out), message: out.trim() });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = router;
