<template>
  <div>
    <div v-if="!store.serial" class="card muted">请先选择一个设备。</div>
    <div v-else>
      <div class="card">
        <div class="row" style="justify-content:space-between">
          <div class="row">
            <button class="btn ghost sm" @click="goUp">上级</button>
            <input v-model="dir" style="min-width:300px" @keyup.enter="load" />
            <button class="btn sm" @click="load">进入</button>
            <button class="btn sm" @click="mkdir">新建文件夹</button>
            <button class="btn sm" @click="$refs.f.click()">上传文件</button>
            <input ref="f" type="file" hidden @change="upload" />
          </div>
          <span class="muted">{{ items.length }} 项</span>
        </div>

        <div v-if="pushJobs.length" style="margin-top:10px">
          <div v-for="t in pushJobs" :key="t.id" style="margin:6px 0">
            <div class="row" style="justify-content:space-between">
              <span>{{ t.message || '上传' }} · {{ t.serial }}</span>
              <span :style="{color: t.error ? 'var(--red)' : t.done ? 'var(--green)' : ''}">
                {{ t.error ? '失败' : t.done ? '完成' : t.percent + '%' }}
              </span>
            </div>
            <div class="progress"><span :style="{width: (t.error ? 100 : t.percent) + '%', background: t.error ? 'var(--red)' : ''}"></span></div>
          </div>
        </div>
      </div>

      <div class="card">
        <table>
          <thead><tr><th>名称</th><th>大小</th><th>修改时间</th><th style="width:180px">操作</th></tr></thead>
          <tbody>
            <tr v-for="it in items" :key="it.name" @dblclick="dbl(it, $event)" style="cursor:pointer">
              <td>
                <span v-if="it.isDir" style="color:var(--accent)">📁</span>
                <span v-else>📄</span>
                {{ it.name }}
              </td>
              <td class="muted">{{ it.isDir ? '-' : fmtSize(it.size) }}</td>
              <td class="muted">{{ fmtTime(it.mtime) }}</td>
              <td class="row">
                <button v-if="it.isDir" class="btn sm" @click="enter(it.name)">打开</button>
                <button v-else class="btn ghost sm" @click="download(it)">下载</button>
                <button class="btn danger sm" @click="del(it)">删除</button>
              </td>
            </tr>
            <tr v-if="!items.length"><td colspan="4" class="muted">空目录</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted } from 'vue';
import { store, showToast } from '../store';
import { apiGet, apiPost, apiUpload, downloadUrl } from '../api';

const dir = ref('/sdcard');
const items = ref([]);
const f = ref(null);
const history = ref([]);

const pushJobs = computed(() => Object.values(store.tasks).filter((t) => t.kind === 'push'));

async function load() {
  if (!store.serial) return;
  try {
    const r = await apiGet(`/files/${encodeURIComponent(store.serial)}/list?path=${encodeURIComponent(dir.value)}`);
    items.value = r.list;
    dir.value = r.dir;
  } catch (e) { showToast(e.message); }
}

function enter(name) {
  history.value.push(dir.value);
  dir.value = `${dir.value.replace(/\/$/, '')}/${name}`;
  load();
}
// 双击文件夹行进入；双击落在操作按钮上时不触发（避免按钮单击+行双击连进两次）
function dbl(it, e) {
  if (e && e.target && e.target.closest && e.target.closest('button')) return;
  if (it.isDir) enter(it.name);
}
function goUp() {
  const parent = dir.value.replace(/\/$/, '').split('/').slice(0, -1).join('/') || '/';
  history.value.push(dir.value);
  dir.value = parent;
  load();
}
async function upload(e) {
  const file = e.target.files[0];
  if (!file) return;
  const jobId = `push_${Date.now()}`;
  const form = new FormData();
  form.append('file', file);
  form.append('path', dir.value);
  form.append('jobId', jobId);
  try {
    await apiUpload(`/files/${encodeURIComponent(store.serial)}/upload?jobId=${jobId}`, form);
    load();
  } catch (err) { showToast(err.message); }
  e.target.value = '';
}
function download(it) {
  const full = `${dir.value.replace(/\/$/, '')}/${it.name}`;
  window.open(downloadUrl(`/files/${encodeURIComponent(store.serial)}/download?path=${encodeURIComponent(full)}`), '_blank');
}
async function del(it) {
  if (!confirm(`删除 ${it.name} ？`)) return;
  const full = `${dir.value.replace(/\/$/, '')}/${it.name}`;
  try {
    await apiPost(`/files/${encodeURIComponent(store.serial)}/delete`, { path: full, recursive: it.isDir });
    load();
  } catch (e) { showToast(e.message); }
}
async function mkdir() {
  const name = prompt('新建文件夹名称');
  if (!name) return;
  const full = `${dir.value.replace(/\/$/, '')}/${name}`;
  try {
    await apiPost(`/files/${encodeURIComponent(store.serial)}/mkdir`, { path: full });
    load();
  } catch (e) { showToast(e.message); }
}

function fmtSize(n) {
  if (!n) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(1)} ${u[i]}`;
}
function fmtTime(t) {
  if (!t) return '-';
  const d = new Date(t);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

watch(() => store.serial, () => { dir.value = '/sdcard'; load(); });
onMounted(() => { if (store.serial) load(); });
</script>
