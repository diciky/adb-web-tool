<template>
  <div class="card log-panel">
    <div class="row" style="justify-content:space-between; margin-bottom:8px">
      <h3 style="margin:0">实时日志（服务端）</h3>
      <div class="row">
        <span class="muted">WebSocket {{ store.wsReady ? '已连接' : '未连接' }}</span>
        <button class="btn ghost sm" @click="clearLogs">清空</button>
      </div>
    </div>
    <div ref="box" class="log-box">
      <div v-for="(l, i) in store.logs" :key="i" class="log-line" :class="'lvl-' + l.level">
        <span class="log-time">{{ fmt(l.time) }}</span>
        <span class="log-level">{{ l.level }}</span>
        <span class="log-msg">{{ l.message }}</span>
      </div>
      <div v-if="!store.logs.length" class="muted">暂无日志，操作设备时这里会实时显示服务端输出</div>
    </div>
  </div>
</template>

<script setup>
import { ref, watch, nextTick } from 'vue';
import { store, clearLogs } from '../store';

const box = ref(null);
function fmt(t) {
  const d = new Date(t);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
watch(
  () => store.logs.length,
  async () => {
    await nextTick();
    if (box.value) box.value.scrollTop = box.value.scrollHeight;
  }
);
</script>

<style scoped>
.log-panel { display: flex; flex-direction: column; }
.log-box {
  background: #0d1117;
  color: #c9d1d9;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 10px;
  height: 60vh;
  overflow: auto;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px;
  line-height: 1.6;
}
.log-line { display: flex; gap: 8px; white-space: pre-wrap; word-break: break-all; }
.log-time { color: #6e7681; flex: 0 0 auto; }
.log-level { flex: 0 0 48px; text-transform: uppercase; }
.lvl-info .log-level { color: #58a6ff; }
.lvl-warn .log-level { color: #d29922; }
.lvl-error .log-level { color: #f85149; }
.log-msg { flex: 1; }
</style>
