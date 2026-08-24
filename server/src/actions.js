const adb = require('./adb');
const fs = require('fs');
const path = require('path');
const config = require('./config');

async function installLocal(serial, localPath) {
  const device = adb.getDevice(serial);
  const remote = `/data/local/tmp/adbweb_${Date.now()}_${path.basename(localPath)}`;
  const transfer = await device.push(localPath, remote);
  await new Promise((resolve, reject) => {
    transfer.on('end', resolve);
    transfer.on('error', reject);
  });
  await device.installRemote(remote);
  return { ok: true };
}

async function uninstall(serial, pkg) {
  const device = adb.getDevice(serial);
  let out = await adb.util.readAll(await device.shell(`pm uninstall ${pkg}`));
  let result = out.toString('utf8');
  if (!/Success/i.test(result)) {
    out = await adb.util.readAll(await device.shell(`pm uninstall --user 0 ${pkg}`));
    result = out.toString('utf8');
  }
  return { ok: /Success/i.test(result), message: result.trim() };
}

async function executeAction(serial, action, params = {}) {
  const device = adb.getDevice(serial);
  try {
    switch (action) {
      case 'reboot':
        await device.reboot();
        return { ok: true };
      case 'recovery':
        await device.reboot('recovery');
        return { ok: true };
      case 'shutdown':
        await adb.util.readAll(await device.shell('reboot -p'));
        return { ok: true };
      case 'wake':
        await adb.util.readAll(await device.shell('input keyevent 224'));
        return { ok: true };
      case 'sleep':
        await adb.util.readAll(await device.shell('input keyevent 223'));
        return { ok: true };
      case 'forceStop':
        await adb.util.readAll(await device.shell(`am force-stop ${params.pkg}`));
        return { ok: true };
      case 'clearData':
        await device.clear(params.pkg);
        return { ok: true };
      case 'launch':
        await adb.util.readAll(await device.shell(`monkey -p ${params.pkg} -c android.intent.category.LAUNCHER 1`));
        return { ok: true };
      case 'uninstall':
        return await uninstall(serial, params.pkg);
      case 'install':
        return await installLocal(serial, params.apkPath);
      default:
        return { ok: false, message: '未知操作: ' + action };
    }
  } catch (e) {
    return { ok: false, message: e.message };
  }
}

module.exports = { executeAction, installLocal, uninstall };
