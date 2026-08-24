<template>
  <div>
    <div v-if="!store.serial" class="card muted">请先在「设备/扫描」中选择一个设备。</div>
    <div v-else>
      <div class="card">
        <div class="row" style="justify-content:space-between">
          <div class="row">
            <button class="btn" @click="load">刷新列表</button>
            <button class="btn ghost" @click="identifyAll" :disabled="identifying">
              {{ identifying ? `识别中 ${doneCount}/${apps.length}` : '识别全部名称/图标' }}
            </button>
            <select v-model="filterType">
              <option value="all">全部</option>
              <option value="user">用户应用</option>
              <option value="system">系统应用</option>
            </select>
            <input v-model="keyword" placeholder="搜索名称 / 包名" style="min-width:200px" />
          </div>
          <span class="muted">{{ filtered.length }} 个应用</span>
        </div>
        <div v-if="identifying" class="progress" style="margin-top:8px"><span :style="{width: pct + '%'}"></span></div>
      </div>

      <div class="card">
        <table>
          <thead>
            <tr><th>应用</th><th>包名</th><th>版本</th><th>类型</th><th style="width:320px">操作</th></tr>
          </thead>
          <tbody>
            <tr v-for="a in filtered" :key="a.pkg">
              <td>
                <img v-if="a.iconUrl" class="app-icon" :src="a.iconUrl" />
                <span v-else class="avatar">{{ (a.name || a.pkg)[0].toUpperCase() }}</span>
                {{ a.name }}
                <span v-if="a.disabled" class="muted">(已停用)</span>
              </td>
              <td class="muted">{{ a.pkg }}</td>
              <td class="muted">{{ a.versionName }}</td>
              <td>
                <span :style="{color: a.type==='system'?'var(--yellow)':'var(--green)'}">
                  {{ a.type === 'system' ? '系统' : '用户' }}
                </span>
              </td>
              <td class="row">
                <button class="btn sm" @click="launch(a)">启动</button>
                <button class="btn ghost sm" @click="clearData(a)">清数据</button>
                <button class="btn ghost sm" @click="forceStop(a)">强停</button>
                <button class="btn ghost sm" @click="exportApk(a)">导出</button>
                <button class="btn danger sm" @click="uninstall(a)">卸载</button>
              </td>
            </tr>
            <tr v-if="!filtered.length"><td colspan="5" class="muted">无应用</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, watch, onMounted } from 'vue';
import { store, showToast } from '../store';
import { apiGet, apiPost, downloadUrl } from '../api';

const apps = ref([]);
const filterType = ref('all');
const keyword = ref('');
const identifying = ref(false);
const doneCount = ref(0);

const filtered = computed(() => {
  const k = keyword.value.trim().toLowerCase();
  return apps.value.filter((a) => {
    if (filterType.value !== 'all' && a.type !== filterType.value) return false;
    if (k && !(a.name.toLowerCase().includes(k) || a.pkg.toLowerCase().includes(k))) return false;
    return true;
  });
});
const pct = computed(() => (apps.value.length ? Math.round((doneCount.value / apps.value.length) * 100) : 0));

async function load() {
  if (!store.serial) return;
  try {
    apps.value = await apiGet(`/apps/${encodeURIComponent(store.serial)}`);
  } catch (e) {
    showToast(e.message);
  }
}

async function identifyOne(a) {
  try {
    const meta = await apiPost(`/apps/${encodeURIComponent(store.serial)}/meta`, { pkg: a.pkg, path: a.path });
    a.name = meta.name || a.pkg;
    a.versionName = meta.versionName || '';
    a.versionCode = meta.versionCode || '';
    a.iconUrl = meta.iconUrl || null;
  } catch (e) {}
  doneCount.value++;
}

async function identifyAll() {
  identifying.value = true;
  doneCount.value = 0;
  const queue = [...apps.value];
  const workers = Array.from({ length: 4 }, async () => {
    while (queue.length) {
      const a = queue.shift();
      await identifyOne(a);
    }
  });
  await Promise.all(workers);
  identifying.value = false;
  showToast('名称识别完成');
}

async function launch(a) {
  try {
    const r = await apiPost(`/apps/${encodeURIComponent(store.serial)}/launch`, { pkg: a.pkg });
    showToast(r.message ? '已尝试启动' : '已启动');
  } catch (e) { showToast(e.message); }
}
async function clearData(a) {
  try { await apiPost(`/apps/${encodeURIComponent(store.serial)}/clear`, { pkg: a.pkg }); showToast('已清除数据: ' + a.name); }
  catch (e) { showToast(e.message); }
}
async function forceStop(a) {
  try { await apiPost(`/apps/${encodeURIComponent(store.serial)}/force-stop`, { pkg: a.pkg }); showToast('已强制停止: ' + a.name); }
  catch (e) { showToast(e.message); }
}
function exportApk(a) {
  window.open(downloadUrl(`/apps/${encodeURIComponent(store.serial)}/export/${encodeURIComponent(a.pkg)}?path=${encodeURIComponent(a.path)}`), '_blank');
}
async function uninstall(a) {
  if (!confirm(`确定卸载 ${a.name} (${a.pkg}) ？`)) return;
  try {
    const r = await apiPost(`/uninstall/${encodeURIComponent(store.serial)}`, { pkg: a.pkg });
    showToast(r.ok ? '卸载成功' : '结果: ' + r.message);
    load();
  } catch (e) { showToast(e.message); }
}

watch(() => store.serial, () => load());
onMounted(() => { if (store.serial) load(); });
</script>
