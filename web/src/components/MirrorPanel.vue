<template>
  <div v-if="!store.serial" class="card muted">请先选择一个设备。</div>
  <div v-else>
    <div class="card">
      <div class="row" style="justify-content:space-between">
        <div class="row">
          <button class="btn" @click="start" :disabled="running">开始镜像</button>
          <button class="btn danger" @click="stop" :disabled="!running">停止</button>
          <label class="muted">间隔
            <input type="number" min="200" step="100" v-model.number="interval" style="width:90px" /> ms
          </label>
        </div>
        <span class="muted">{{ running ? '实时刷新中（约 ' + Math.round(1000 / interval) + ' fps）' : '已停止' }}</span>
      </div>
      <p class="muted">说明：通过循环 screencap 实现实时预览（兼容 Android 4.0+，无需额外组件）。帧率受设备性能限制。</p>

      <div class="row" style="margin-top:8px">
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

    <div class="card">
      <div class="mirror-wrap" ref="wrap" :style="{ position: 'relative', display: 'inline-block', maxWidth: '100%' }">
        <img v-if="running" :key="imgKey" :src="mirrorUrl" @load="syncSize" class="mirror-img" />
        <canvas
          v-if="running"
          ref="anno"
          class="anno-canvas"
          :width="cw"
          :height="ch"
          @mousedown="down"
          @mousemove="move"
          @mouseup="up"
          @mouseleave="up"
        ></canvas>
        <div v-if="!running" class="muted" style="padding:40px">点击「开始镜像」预览屏幕</div>
      </div>
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

const running = ref(false);
const interval = ref(1000);
const imgKey = ref(0);
const wrap = ref(null);
const anno = ref(null);
const cw = ref(640);
const ch = ref(360);

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

function start() { imgKey.value++; running.value = true; }
function stop() { running.value = false; clearAnno(); }
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
  const rect = anno.value.getBoundingClientRect();
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

async function recStart() {
  try {
    const r = await apiPost(`/tools/${encodeURIComponent(store.serial)}/record/start`, { limit: recLimit.value });
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
