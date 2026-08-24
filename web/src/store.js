import { reactive } from 'vue';
import { apiGet, apiPost, wsUrl } from './api';

export const store = reactive({
  devices: [],
  serial: '',
  scanResults: [],
  scanning: false,
  tasks: {},
  wsReady: false,
  toast: '',
});

let ws = null;
let reconnectTimer = null;

export function showToast(msg, ms = 2500) {
  store.toast = msg;
  setTimeout(() => {
    if (store.toast === msg) store.toast = '';
  }, ms);
}

export async function refreshDevices() {
  try {
    store.devices = await apiGet('/devices');
    if (store.serial && !store.devices.find((d) => d.serial === store.serial)) {
      store.serial = '';
    }
    if (!store.serial && store.devices.length) {
      const online = store.devices.find((d) => d.state === 'device');
      store.serial = (online || store.devices[0]).serial;
    }
  } catch (e) {
    showToast('获取设备列表失败: ' + e.message);
  }
}

export function selectDevice(serial) {
  store.serial = serial;
}

export async function startScan(subnet) {
  store.scanning = true;
  store.scanResults = [];
  try {
    await apiPost('/scan', { subnet });
  } catch (e) {
    showToast('扫描启动失败: ' + e.message);
    store.scanning = false;
  }
}

export async function connectDevice(host, port) {
  try {
    const r = await apiPost('/connect', { host, port });
    if (r.code === 'UNAUTHORIZED') {
      showToast('请在电视上确认 USB 调试授权后重试', 4000);
      return false;
    }
    showToast('连接成功: ' + r.serial);
    await refreshDevices();
    if (r.serial) store.serial = r.serial;
    return true;
  } catch (e) {
    showToast('连接失败: ' + e.message, 4000);
    return false;
  }
}

export async function disconnectDevice(serial) {
  await apiPost('/disconnect', { serial });
  await refreshDevices();
}

function handleMessage(msg) {
  switch (msg.type) {
    case 'scan_progress':
      if (!store.scanResults.find((r) => r.serial === msg.serial)) {
        store.scanResults.push({ ip: msg.ip, port: msg.port, serial: msg.serial });
      }
      break;
    case 'scan_done':
      store.scanning = false;
      break;
    case 'task':
      store.tasks[msg.id] = {
        id: msg.id,
        kind: msg.kind,
        serial: msg.serial,
        phase: msg.phase,
        percent: msg.percent || 0,
        message: msg.message || '',
        done: !!msg.done,
        error: msg.error || '',
      };
      break;
    default:
      break;
  }
}

export function connectWS() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  ws = new WebSocket(wsUrl());
  ws.onopen = () => { store.wsReady = true; };
  ws.onmessage = (e) => {
    let msg;
    try { msg = JSON.parse(e.data); } catch (err) { return; }
    handleMessage(msg);
  };
  ws.onclose = () => {
    store.wsReady = false;
    ws = null;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connectWS, 2000);
  };
  ws.onerror = () => { try { ws.close(); } catch (e) {} };
}

export function sendWS(msg) {
  if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}
