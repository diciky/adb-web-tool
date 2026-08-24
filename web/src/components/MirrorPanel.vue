<template>
  <div v-if="!store.serial" class="card muted">请先选择一个设备。</div>
  <div v-else>
    <div class="card">
      <div class="row" style="justify-content:space-between">
        <div class="row">
          <button class="btn" :disabled="running || h264Running" @click="start">开始{{ mode === 'h264' ? '实时' : '镜像' }}</button>
          <button class="btn danger" :disabled="!running && !h264Running" @click="stop">停止</button>
          <label class="muted" v-if="mode === 'shot'">间隔
            <input type="number" min="200" step="100" v-model.number="interval" style="width:90px" /> ms
          </label>
          <span class="muted">{{ mode === 'h264' ? (h264Running ? 'H.264 实时解码中' : '未开始') : (running ? '实时刷新中（约 ' + Math.round(1000 / interval) + ' fps）' : '已停止') }}</span>
        </div>
        <div class="row">
          <button class="btn ghost sm" :class="{ active: mode === 'shot' }" @click="mode = 'shot'">截图轮询</button>
          <button class="btn ghost sm" :class="{ active: mode === 'h264' }" @click="mode = 'h264'">H.264 实时</button>
        </div>
      </div>
      <p class="muted">说明：截图轮询（兼容 Android 4.0+，延迟较高）；H.264 实时（需 Chromium 系浏览器 + 电视支持 screenrecord，低延迟）。失败会自动回退截图模式。</p>

      <div class="row" style="margin-top:8px" v-if="mode === 'shot'">
        <label class="muted">标注工具</label>
        <select v-model="tool">
          <option value="pen">画笔</option>
          <option value="rect">矩形</option>
          <option value="arrow">箭头</option>
          <option value="text">文字</option>
        </select>
        <input type="color" v-model="color" style="width:40px; padding:2px" />
        <button class="btn ghost sm" @click="undo">撤销</button>
        <button class="btn ghost sm" @click="clearAnno">清除标注</button>
        <button class="btn ghost sm" @click="exportAnno">导出 PNG</button>
        <button class="btn ghost sm" @click="sendToDevice">发送到设备</button>
      </div>
    </div>

    <div class="mirror-remote">
      <div class="card mirror-card">
        <div class="mirror-wrap" ref="wrap" :style="{ position: 'relative', display: 'inline-block', maxWidth: '100%' }">
          <img v-if="mode === 'shot' && running" :key="imgKey" :src="mirrorUrl" @load="syncSize" class="mirror-img" />
          <canvas v-if="mode === 'h264' && h264Running" ref="h264Canvas" class="mirror-img"></canvas>
          <canvas
            v-if="mode === 'shot' && running"
            ref="anno"
            class="anno-canvas"
            :width="cw"
            :height="ch"
            @mousedown="down"
            @mousemove="move"
            @mouseup="up"
            @mouseleave="up"
          ></canvas>
          <div v-if="!running && mode !== 'h264'" class="muted" style="padding:40px">点击「开始{{ mode === 'h264' ? '实时' : '镜像' }}」预览屏幕</div>
          <div v-if="mode === 'h264' && !h264Running" class="muted" style="padding:40px">选择「H.264 实时」后点「开始」</div>
        </div>
      </div>
      <RemoteControl />
    </div>

    <div class="card" v-if="recFile">
      <h3>录制完成</h3>
      <p>文件：{{ recFile }}</p>
      <a class="btn" :href="downloadUrl('/files/' + encodeURIComponent(store.serial) + '/download?path=' + encodeURIComponent(recFile))" target="_blank">下载录制文件</a>
    </div>

    <div class="card">
      <div class="row" style="justify-content:space-between">
        <h3 style="margin:0">屏幕录制</h3>
        <div class="row">
          <label class="muted">时长上限
            <input type="number" min="1" max="180" v-model.number="recLimit" style="width:70px" /> 秒
          </label>
          <button class="btn" v-if="!recording" @click="recStart">开始录制</button>
          <button class="btn danger" v-else @click="recStop">停止录制</button>
        </div>
      </div>
      <p class="muted">使用设备自带 screenrecord（Android 4.4+，部分 TV 移除该命令则不可用）。</p>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onUnmounted } from 'vue';
import { store, showToast } from '../store';
import { downloadUrl, apiPost, apiUpload } from '../api';
import RemoteControl from './RemoteControl.vue';

const running = ref(false);
const interval = ref(1000);
const imgKey = ref(0);
const wrap = ref(null);
const anno = ref(null);
const h264Canvas = ref(null);
const cw = ref(640);
const ch = ref(360);

const mode = ref('shot');
const h264Running = ref(false);

const tool = ref('pen');
const color = ref('#ff3b30');
const shapes = ref([]);
let drawing = false;
let startPt = null;

const recLimit = ref(30);
const recording = ref(false);
const recFile = ref('');

const mirrorUrl = computed(() => {
  const t = new URLSearchParams(location.search).get('token') || '';
  return `/api/tools/${encodeURIComponent(store.serial)}/mirror?interval=${interval.value}${t ? '&token=' + t : ''}#${imgKey.value}`;
});

function start() {
  if (mode.value === 'h264') startH264();
  else { imgKey.value++; running.value = true; }
}
function stop() {
  if (mode.value === 'h264') stopH264();
  else { running.value = false; clearAnno(); }
}

/* ---------- 截图轮询标注 ---------- */
function syncSize() {
  const img = wrap.value.querySelector('img');
  if (img) { cw.value = img.clientWidth; ch.value = img.clientHeight; }
}
function down(e) {
  const rect = anno.value.getBoundingClientRect();
  startPt = { x: e.clientX - rect.left, y: e.clientY - rect.top };
  if (tool.value === 'text') {
    const txt = prompt('输入标注文字（支持中文）');
    if (txt) shapes.value.push({ type: 'text', x: startPt.x, y: startPt.y, text: txt, color: color.value });
    drawing = false;
    redraw();
    return;
  }
  drawing = true;
}
function move(e) {
  if (!drawing) return;
  const rect = anno.value.getBoundingClientRect();
  const pt = { x: e.clientX - rect.left, y: e.clientY - rect.top };
  const cur = shapes.value.slice();
  cur.push({ type: tool.value, x1: startPt.x, y1: startPt.y, x2: pt.x, y2: pt.y, color: color.value });
  drawShapes(cur);
}
function up() {
  if (!drawing) return;
  drawing = false;
  const last = shapes.value[shapes.value.length - 1];
  if (last && (Math.abs(last.x2 - last.x1) < 2 && Math.abs(last.y2 - last.y1) < 2)) shapes.value.pop();
  redraw();
}
function redraw() { drawShapes(shapes.value); }
function drawShapes(list) {
  const ctx = anno.value.getContext('2d');
  ctx.clearRect(0, 0, cw.value, ch.value);
  for (const s of list) {
    ctx.strokeStyle = s.color; ctx.fillStyle = s.color; ctx.lineWidth = 3;
    if (s.type === 'pen' || s.type === 'arrow' || s.type === 'rect') {
      ctx.beginPath();
      if (s.type === 'rect') { ctx.rect(s.x1, s.y1, s.x2 - s.x1, s.y2 - s.y1); }
      else { ctx.moveTo(s.x1, s.y1); ctx.lineTo(s.x2, s.y2); }
      ctx.stroke();
      if (s.type === 'arrow') {
        const ang = Math.atan2(s.y2 - s.y1, s.x2 - s.x1);
        ctx.beginPath();
        ctx.moveTo(s.x2, s.y2);
        ctx.lineTo(s.x2 - 12 * Math.cos(ang - 0.4), s.y2 - 12 * Math.sin(ang - 0.4));
        ctx.lineTo(s.x2 - 12 * Math.cos(ang + 0.4), s.y2 - 12 * Math.sin(ang + 0.4));
        ctx.closePath(); ctx.fill();
      }
    } else if (s.type === 'text') {
      ctx.font = '16px sans-serif';
      ctx.fillText(s.text, s.x, s.y + 14);
    }
  }
}
function undo() { shapes.value.pop(); redraw(); }
function clearAnno() { shapes.value = []; if (anno.value) drawShapes([]); }

function exportAnno() {
  const img = wrap.value.querySelector('img');
  const out = document.createElement('canvas');
  out.width = cw.value; out.height = ch.value;
  const octx = out.getContext('2d');
  if (img) octx.drawImage(img, 0, 0, cw.value, ch.value);
  octx.drawImage(anno.value, 0, 0);
  const a = document.createElement('a');
  a.download = `annotated_${Date.now()}.png`;
  a.href = out.toDataURL('image/png');
  a.click();
}

async function sendToDevice() {
  const img = wrap.value.querySelector('img');
  const out = document.createElement('canvas');
  out.width = cw.value; out.height = ch.value;
  const octx = out.getContext('2d');
  if (img) octx.drawImage(img, 0, 0, cw.value, ch.value);
  octx.drawImage(anno.value, 0, 0);
  out.toBlob(async (blob) => {
    const form = new FormData();
    form.append('file', blob, 'annotated.png');
    form.append('path', '/sdcard');
    try {
      await apiUpload(`/files/${encodeURIComponent(store.serial)}/upload`, form);
      showToast('已发送到设备 /sdcard/annotated.png');
    } catch (e) { showToast(e.message); }
  }, 'image/png');
}

/* ---------- H.264 实时流 ---------- */
let h264Ws = null;
let decoder = null;
let h264Buf = new Uint8Array(0);
let sps = null;
let pps = null;
let h264Pts = 0;

function findStart(code, from) {
  for (let i = from; i + 3 <= code.length; i++) {
    if (code[i] === 0 && code[i + 1] === 0 && code[i + 2] === 1) return i;
  }
  return -1;
}
function startCodeLen(nal) {
  if (nal[2] === 1) return 3;
  if (nal[3] === 0 && nal[4] === 0 && nal[5] === 1) return 4;
  return 3;
}
function buildAvcC(spsNal, ppsNal) {
  const out = new Uint8Array(11 + spsNal.length + ppsNal.length);
  let i = 0;
  out[i++] = 1;
  out[i++] = spsNal[1];
  out[i++] = spsNal[2];
  out[i++] = spsNal[3];
  out[i++] = 0xff;
  out[i++] = 0xe1;
  out[i++] = (spsNal.length >> 8) & 0xff;
  out[i++] = spsNal.length & 0xff;
  out.set(spsNal, i); i += spsNal.length;
  out[i++] = 0x01;
  out[i++] = (ppsNal.length >> 8) & 0xff;
  out[i++] = ppsNal.length & 0xff;
  out.set(ppsNal, i); i += ppsNal.length;
  return out;
}
function codecFromSps(spsNal) {
  const p = spsNal[1].toString(16).padStart(2, '0');
  const c = spsNal[2].toString(16).padStart(2, '0');
  const l = spsNal[3].toString(16).padStart(2, '0');
  return 'avc1.' + p + c + l;
}
function toLengthPrefixed(payload) {
  const out = new Uint8Array(4 + payload.length);
  out[0] = (payload.length >> 24) & 0xff;
  out[1] = (payload.length >> 16) & 0xff;
  out[2] = (payload.length >> 8) & 0xff;
  out[3] = payload.length & 0xff;
  out.set(payload, 4);
  return out;
}
function configureDecoder() {
  try {
    decoder = new VideoDecoder({
      output: (frame) => { drawFrame(frame); frame.close(); },
      error: (e) => { console.warn('decode error', e); showToast('H.264 解码错误: ' + e.message); },
    });
    decoder.configure({ codec: codecFromSps(sps), description: buildAvcC(sps, pps), optimizeForLatency: true });
  } catch (e) {
    showToast('浏览器不支持该 H.264 配置，已回退截图模式');
    mode.value = 'shot';
    stopH264();
  }
}
function drawFrame(frame) {
  const c = h264Canvas.value;
  if (!c) { frame.close(); return; }
  if (c.width !== frame.displayWidth) c.width = frame.displayWidth;
  if (c.height !== frame.displayHeight) c.height = frame.displayHeight;
  const ctx = c.getContext('2d');
  ctx.drawImage(frame, 0, 0);
  frame.close();
}
function feedNal(nal) {
  const sc = startCodeLen(nal);
  const payload = nal.slice(sc);
  if (!payload.length) return;
  const t = payload[0] & 0x1f;
  if (t === 7) sps = payload;
  else if (t === 8) pps = payload;
  else if (t >= 1 && t <= 5) {
    if (!decoder && sps && pps) configureDecoder();
    if (decoder && decoder.state === 'configured') {
      const isKey = t === 5;
      try {
        decoder.decode(new EncodedVideoChunk({ type: isKey ? 'key' : 'delta', timestamp: h264Pts, duration: 33333, data: toLengthPrefixed(payload) }));
      } catch (e) {
        showToast('解码失败: ' + e.message);
      }
      h264Pts += 33333;
    }
  }
}
function onH264Data(u8) {
  const merged = new Uint8Array(h264Buf.length + u8.length);
  merged.set(h264Buf);
  merged.set(u8, h264Buf.length);
  h264Buf = merged;
  let idx = findStart(h264Buf, 0);
  while (idx !== -1) {
    const next = findStart(h264Buf, idx + 3);
    if (next === -1) break;
    feedNal(h264Buf.slice(idx, next));
    h264Buf = h264Buf.slice(next);
    idx = findStart(h264Buf, 0);
  }
}
function startH264() {
  if (!('VideoDecoder' in window)) {
    showToast('当前浏览器不支持 WebCodecs，已切回截图模式');
    mode.value = 'shot';
    return;
  }
  resetH264();
  h264Running.value = true;
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const token = new URLSearchParams(location.search).get('token') || '';
  const ws = new WebSocket(`${proto}://${location.host}/ws${token ? '?token=' + token : ''}`);
  h264Ws = ws;
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => { ws.send(JSON.stringify({ type: 'subscribe', channel: 'mirror_h264', serial: store.serial })); };
  ws.onmessage = (e) => {
    if (typeof e.data === 'string') {
      let m; try { m = JSON.parse(e.data); } catch (_) { return; }
      if (m.type === 'mirror_h264_error') {
        showToast('H.264 启动失败: ' + m.message + '，已回退截图模式');
        stopH264();
        mode.value = 'shot';
      }
    } else {
      onH264Data(new Uint8Array(e.data));
    }
  };
  ws.onclose = () => { h264Running.value = false; };
  ws.onerror = () => { showToast('H.264 连接错误'); };
}
function stopH264() {
  if (h264Ws) {
    try { h264Ws.send(JSON.stringify({ type: 'unsubscribe', channel: 'mirror_h264', serial: store.serial })); } catch (_) {}
    try { h264Ws.close(); } catch (_) {}
    h264Ws = null;
  }
  if (decoder) { try { decoder.close(); } catch (_) {} decoder = null; }
  h264Running.value = false;
  resetH264();
}
function resetH264() {
  h264Buf = new Uint8Array(0);
  sps = null;
  pps = null;
  h264Pts = 0;
  if (decoder) { try { decoder.close(); } catch (_) {} decoder = null; }
}

/* ---------- 录制 ---------- */
async function recStart() {
  try {
    await apiPost(`/tools/${encodeURIComponent(store.serial)}/record/start`, { limit: recLimit.value });
    recording.value = true;
    recFile.value = '';
    showToast('开始录制');
  } catch (e) { showToast(e.message); }
}
async function recStop() {
  try {
    const r = await apiPost(`/tools/${encodeURIComponent(store.serial)}/record/stop`, {});
    recording.value = false;
    recFile.value = r.file;
  } catch (e) { showToast(e.message); }
}

onUnmounted(() => { stop(); });
</script>

<style scoped>
.mirror-remote {
  display: flex;
  gap: 16px;
  align-items: flex-start;
  flex-wrap: wrap;
}
.mirror-card {
  flex: 1;
  min-width: 320px;
}
</style>
