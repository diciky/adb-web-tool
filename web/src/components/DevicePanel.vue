<template>
  <div>
    <div class="card">
      <h3>手动连接</h3>
      <div class="row">
        <input v-model="host" placeholder="设备 IP，如 192.168.1.50" />
        <input v-model="port" placeholder="端口" style="width:90px" />
        <button class="btn" :disabled="!host" @click="doConnect">连接</button>
        <span class="muted">默认端口 5555（安卓 TV 需已开启「网络 ADB 调试」）</span>
      </div>
    </div>

    <div class="card">
      <div class="row" style="justify-content:space-between">
        <h3 style="margin:0">局域网扫描</h3>
        <div class="row">
          <select v-model="subnet">
            <option value="">自动检测网段</option>
            <option v-for="s in subnets" :key="s" :value="s">{{ s }}</option>
          </select>
          <button class="btn" :disabled="store.scanning" @click="scan">
            {{ store.scanning ? '扫描中...' : '开始扫描' }}
          </button>
        </div>
      </div>
      <p class="muted">扫描局域网内在 5555（可配置）端口开放 ADB 的设备。</p>
      <ul>
        <li v-for="r in store.scanResults" :key="r.serial" class="row" style="justify-content:space-between; padding:6px 0">
          <span>{{ r.ip }}:{{ r.port }}</span>
          <button class="btn sm" @click="connect(r.ip, r.port)">连接</button>
        </li>
        <li v-if="!store.scanResults.length" class="muted">暂无结果</li>
      </ul>
    </div>

    <div class="card">
      <h3>已连接设备</h3>
      <div v-if="!store.devices.length" class="muted">尚未连接任何设备</div>
      <div v-for="d in store.devices" :key="d.serial" class="row" style="justify-content:space-between; padding:8px 0; border-bottom:1px solid var(--border)">
        <div class="row">
          <span class="status-dot" :class="'status-' + d.state"></span>
          <span>{{ d.serial }}</span>
          <span class="muted">{{ stateText(d.state) }}</span>
        </div>
        <div class="row">
          <button class="btn ghost sm" @click="showInfo(d.serial)">详情</button>
          <button class="btn danger sm" @click="disconnect(d.serial)">断开</button>
        </div>
      </div>
    </div>

    <div v-if="info" class="modal-mask" @click.self="info = null">
      <div class="modal">
        <h3>设备信息</h3>
        <table>
          <tr v-for="(v, k) in info" :key="k"><th style="width:140px">{{ k }}</th><td>{{ v }}</td></tr>
        </table>
        <div class="row" style="justify-content:flex-end; margin-top:10px">
          <button class="btn" @click="info = null">关闭</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted } from 'vue';
import { store, startScan, connectDevice, disconnectDevice, refreshDevices, showToast } from '../store';
import { apiGet } from '../api';

const host = ref('');
const port = ref('5555');
const subnets = ref([]);
const info = ref(null);

function stateText(s) {
  return s === 'device' ? '在线' : s === 'unauthorized' ? '待授权' : s === 'offline' ? '离线' : s;
}

async function doConnect() {
  const ok = await connectDevice(host.value, port.value);
  if (ok) { host.value = ''; }
}
async function connect(ip, p) {
  await connectDevice(ip, p);
}
async function disconnect(serial) {
  await disconnectDevice(serial);
}
async function showInfo(serial) {
  try {
    info.value = await apiGet(`/device/${encodeURIComponent(serial)}/info`);
  } catch (e) {
    showToast(e.message);
  }
}

onMounted(async () => {
  try { subnets.value = await apiGet('/subnets'); } catch (e) {}
});
</script>
