<template>
  <div v-if="!store.serial" class="card muted">请先选择一个设备。</div>
  <div v-else class="grid cols3">
    <div class="card">
      <h3>截图</h3>
      <button class="btn" @click="capture">截取当前屏幕</button>
      <div v-if="screenshot" class="modal-mask" @click.self="screenshot = null">
        <div class="modal">
          <img :src="screenshot" />
          <div class="row" style="justify-content:flex-end; margin-top:8px">
            <button class="btn ghost" @click="screenshot = null">关闭</button>
          </div>
        </div>
      </div>
    </div>

    <div class="card">
      <h3>文本输入</h3>
      <p class="muted">注：Android 的 input text 不支持中文/非 ASCII，请输英文或拼音。</p>
      <div class="row">
        <input v-model="text" @keyup.enter="sendText" placeholder="英文文本" />
        <button class="btn" @click="sendText">发送</button>
      </div>
      <h3 style="margin-top:14px">电源</h3>
      <div class="row">
        <button class="btn ghost sm" @click="power('reboot')">重启</button>
        <button class="btn ghost sm" @click="power('recovery')">进入 Recovery</button>
        <button class="btn ghost sm" @click="power('shutdown')">关机</button>
      </div>
    </div>

    <div class="card">
      <h3>中文 / 任意文本输入</h3>
      <p class="muted">通过剪贴板方式输入（兼容中文）。推荐在电视安装 Clipper 应用以获得最佳效果；未安装时尝试 service call（Android≤6）或退回 ASCII。</p>
      <textarea v-model="cnText" rows="3" style="width:100%" placeholder="可输入中文或任意文本"></textarea>
      <div class="row" style="margin-top:8px">
        <button class="btn" @click="sendClipboard(false)">复制到剪贴板</button>
        <button class="btn ghost" @click="sendClipboard(true)">复制并粘贴</button>
        <span class="muted" v-if="clipMethod">方式：{{ clipMethod }}</span>
      </div>
    </div>

    <div class="card" style="grid-column: span 3">
      <h3>Shell 终端</h3>
      <div style="height:220px; overflow:auto; background:#000; border-radius:8px; padding:8px; font-family:monospace; font-size:12px">
        <div v-for="(l, i) in shellLines" :key="i" style="white-space:pre-wrap">{{ l }}</div>
      </div>
      <div class="row" style="margin-top:8px">
        <input v-model="shellInput" style="flex:1" @keyup.enter="sendShell" placeholder="输入 shell 命令，回车执行" />
        <button class="btn" @click="sendShell">执行</button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, watch, onUnmounted } from 'vue';
import { store, showToast, sendWS } from '../store';
import { apiPost, downloadUrl } from '../api';

const screenshot = ref(null);
const text = ref('');
const cnText = ref('');
const clipMethod = ref('');
const shellLines = ref([]);
const shellInput = ref('');
let localWs = null;

function capture() {
  const ts = Date.now();
  screenshot.value = downloadUrl(`/tools/${encodeURIComponent(store.serial)}/screenshot`) + '#' + ts;
}
async function key(code) {
  try { await apiPost(`/tools/${encodeURIComponent(store.serial)}/key`, { code }); } catch (e) { showToast(e.message); }
}
async function sendText() {
  if (!text.value) return;
  try {
    await apiPost(`/tools/${encodeURIComponent(store.serial)}/text`, { text: text.value });
    text.value = '';
  } catch (e) { showToast(e.message); }
}
async function power(action) {
  if (!confirm(`确定执行：${action}？`)) return;
  try {
    await apiPost(`/tools/${encodeURIComponent(store.serial)}/power`, { action });
    showToast('已发送');
  } catch (e) { showToast(e.message); }
}
async function wake(action) {
  try { await apiPost(`/tools/${encodeURIComponent(store.serial)}/wake`, { action }); } catch (e) { showToast(e.message); }
}
async function sendClipboard(paste) {
  if (!cnText.value) return;
  try {
    const r = await apiPost(`/tools/${encodeURIComponent(store.serial)}/clipboard`, { text: cnText.value, paste });
    clipMethod.value = r.method;
    showToast('已发送（方式：' + r.method + '）');
  } catch (e) { showToast(e.message); }
}

function ensureWs() {
  if (localWs && localWs.readyState === WebSocket.OPEN) return;
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const token = new URLSearchParams(location.search).get('token') || '';
  localWs = new WebSocket(`${proto}://${location.host}/ws${token ? '?token=' + token : ''}`);
  localWs.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === 'shell_out' && m.serial === store.serial) {
      shellLines.value.push(m.data);
      if (shellLines.value.length > 500) shellLines.value.shift();
    } else if (m.type === 'shell_exit') {
      shellLines.value.push('\r\n[连接已关闭]');
    }
  };
}
function sendShell() {
  if (!shellInput.value) return;
  ensureWs();
  sendWS({ type: 'shell', serial: store.serial, data: shellInput.value + '\n' });
  shellInput.value = '';
}

onUnmounted(() => { if (localWs) localWs.close(); });
</script>
