<template>
  <div v-if="!store.serial" class="card muted">请先选择一个设备。</div>
  <div v-else>
    <div class="card">
      <div class="row" style="justify-content:space-between">
        <h3 style="margin:0">设备健康监控</h3>
        <div class="row">
          <span class="muted">采样间隔 2s · 保留 {{ maxPoints }} 点</span>
          <button class="btn" @click="test" :disabled="testing">网络测速</button>
        </div>
      </div>
    </div>

    <div class="grid" style="grid-template-columns: repeat(auto-fit, minmax(280px, 1fr))">
      <div class="card">
        <h4>CPU 使用率 (%)</h4>
        <ChartCanvas :series="[{ label: 'CPU', color: '#3b82f6', data: cpuData }]" :max="100" :height="160" />
        <div class="muted" v-if="last && last.cpu">总: {{ last.cpu.percent }}%</div>
      </div>
      <div class="card">
        <h4>内存使用率 (%)</h4>
        <ChartCanvas :series="[{ label: 'MEM', color: '#22c55e', data: memData }]" :max="100" :height="160" />
        <div class="muted" v-if="last && last.mem">
          已用 {{ fmt(last.mem.used) }} / {{ fmt(last.mem.total) }}
        </div>
      </div>
    </div>

    <div class="card">
      <h4>存储</h4>
      <div v-for="s in (last ? last.storage : [])" :key="s.mount" class="row" style="margin:6px 0; justify-content:space-between">
        <span style="min-width:160px">{{ s.mount }}</span>
        <div class="progress" style="flex:1; margin:0 10px">
          <span :style="{ width: s.percent + '%', background: s.percent > 85 ? 'var(--red)' : 'var(--accent)' }"></span>
        </div>
        <span class="muted">{{ s.percent }}% · {{ fmt(s.used) }}/{{ fmt(s.total) }}</span>
      </div>
      <div v-if="last && last.battery" class="row" style="margin-top:10px">
        <span>电池：{{ last.battery.level != null ? last.battery.level + '%' : '未知' }}</span>
        <span class="muted" v-if="last.battery.tempC != null">温度 {{ last.battery.tempC }}°C</span>
        <span class="muted" v-if="last.wifi">WiFi：{{ last.wifi.ssid || '?' }} {{ last.wifi.rxMbps ? last.wifi.rxMbps + 'Mbps' : '' }} RSSI {{ last.wifi.rssi }}</span>
      </div>
    </div>

    <div class="card" v-if="net">
      <h4>网络测速结果</h4>
      <div class="row">
        <div class="card" style="flex:1"><b>Ping</b><br />{{ net.ping.avg != null ? net.ping.avg + ' ms' : '失败' }} (丢包 {{ net.ping.loss }}%)</div>
        <div class="card" style="flex:1"><b>推送速率</b><br />{{ net.throughput.pushMbps }} MB/s</div>
        <div class="card" style="flex:1"><b>拉取速率</b><br />{{ net.throughput.pullMbps }} MB/s</div>
      </div>
      <div class="muted" v-if="net.wifi">WiFi 速率 {{ net.wifi.rxMbps }}Mbps · RSSI {{ net.wifi.rssi }}</div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted, computed } from 'vue';
import { store, showToast } from '../store';
import { apiGet, apiPost } from '../api';
import ChartCanvas from './ChartCanvas.vue';

const maxPoints = 60;
const cpuData = ref([]);
const memData = ref([]);
const last = ref(null);
const net = ref(null);
const testing = ref(false);
let timer = null;

function fmt(n) {
  if (!n) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(1)} ${u[i]}`;
}

async function poll() {
  try {
    const s = await apiGet(`/health/${encodeURIComponent(store.serial)}/snapshot`);
    last.value = s;
    if (s.cpu && s.cpu.percent != null) {
      cpuData.value.push(s.cpu.percent);
      if (cpuData.value.length > maxPoints) cpuData.value.shift();
    }
    if (s.mem) {
      memData.value.push(s.mem.percent);
      if (memData.value.length > maxPoints) memData.value.shift();
    }
  } catch (e) {}
}

async function test() {
  testing.value = true;
  try {
    net.value = await apiPost(`/nettest/${encodeURIComponent(store.serial)}`, { host: '8.8.8.8' });
  } catch (e) { showToast(e.message); }
  testing.value = false;
}

onMounted(() => { poll(); timer = setInterval(poll, 2000); });
onUnmounted(() => { if (timer) clearInterval(timer); });
</script>
