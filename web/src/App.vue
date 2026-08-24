<template>
  <div class="app">
    <div class="topbar">
      <span class="logo">📺 ADB 远程管理</span>
      <span class="muted">Web 版 · 安卓 TV 4.0–9.0</span>
      <span class="spacer"></span>
      <select class="device-select" :value="store.serial" @change="selectDevice($event.target.value)">
        <option value="">未选择设备</option>
        <option v-for="d in store.devices" :key="d.serial" :value="d.serial">
          {{ d.serial }} ({{ stateText(d.state) }})
        </option>
      </select>
      <span v-if="store.serial" class="status-dot" :class="'status-' + currentState()"></span>
      <button class="btn ghost sm" @click="refreshDevices">刷新</button>
    </div>

    <div class="tabs">
      <div v-for="t in tabs" :key="t.key" class="tab" :class="{ active: tab === t.key }" @click="tab = t.key">
        {{ t.label }}
      </div>
    </div>

    <div class="content">
      <DevicePanel v-if="tab === 'devices'" />
      <AppsPanel v-else-if="tab === 'apps'" />
      <InstallPanel v-else-if="tab === 'install'" />
      <FilesPanel v-else-if="tab === 'files'" />
      <MirrorPanel v-else-if="tab === 'mirror'" />
      <CastReceiver v-else-if="tab === 'castrecv'" />
      <CastSender v-else-if="tab === 'castsend'" />
      <HealthPanel v-else-if="tab === 'health'" />
      <AutoStartPanel v-else-if="tab === 'autostart'" />
      <BatchPanel v-else-if="tab === 'batch'" />
      <ToolsPanel v-else-if="tab === 'tools'" />
      <LogPanel v-else-if="tab === 'logs'" />
    </div>

    <div v-if="store.toast" class="toast">{{ store.toast }}</div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue';
import { store, refreshDevices, selectDevice, connectWS } from './store';
import DevicePanel from './components/DevicePanel.vue';
import AppsPanel from './components/AppsPanel.vue';
import InstallPanel from './components/InstallPanel.vue';
import FilesPanel from './components/FilesPanel.vue';
import ToolsPanel from './components/ToolsPanel.vue';
import MirrorPanel from './components/MirrorPanel.vue';
import CastReceiver from './components/CastReceiver.vue';
import CastSender from './components/CastSender.vue';
import HealthPanel from './components/HealthPanel.vue';
import AutoStartPanel from './components/AutoStartPanel.vue';
import BatchPanel from './components/BatchPanel.vue';
import LogPanel from './components/LogPanel.vue';

const tabs = [
  { key: 'devices', label: '设备/扫描' },
  { key: 'apps', label: '应用管理' },
  { key: 'install', label: '安装 APK' },
  { key: 'files', label: '文件传输' },
  { key: 'mirror', label: '屏幕镜像' },
  { key: 'castrecv', label: '投屏接收' },
  { key: 'castsend', label: '投屏发送' },
  { key: 'health', label: '监控/测速' },
  { key: 'autostart', label: '自启管理' },
  { key: 'batch', label: '批量/定时' },
  { key: 'tools', label: '工具箱' },
  { key: 'logs', label: '实时日志' },
];
const tab = ref('devices');
const allowedTabs = tabs.map((t) => t.key);
const deep = new URLSearchParams(location.search).get('tab');
if (deep && allowedTabs.includes(deep)) tab.value = deep;

function stateText(s) {
  return s === 'device' ? '在线' : s === 'unauthorized' ? '待授权' : s === 'offline' ? '离线' : s;
}
function currentState() {
  const d = store.devices.find((x) => x.serial === store.serial);
  return d ? d.state : '';
}

let timer = null;
onMounted(() => {
  connectWS();
  refreshDevices();
  timer = setInterval(refreshDevices, 6000);
});
onUnmounted(() => { if (timer) clearInterval(timer); });
</script>
