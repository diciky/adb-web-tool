<template>
  <div v-if="!store.serial" class="card muted">请先选择一个设备。</div>
  <div v-else>
    <div class="card">
      <div class="row" style="justify-content:space-between">
        <h3 style="margin:0">开机自启管理</h3>
        <div class="row">
          <span class="muted">共 {{ apps.length }} 个可自启应用</span>
          <button class="btn" @click="load">刷新</button>
        </div>
      </div>
      <p class="muted">列出声明了 RECEIVE_BOOT_COMPLETED 的应用，可单独开关其开机广播接收器；部分厂商 ROM 由管家控制，无法解析时可「禁用整个应用」。</p>
    </div>

    <div class="card" v-for="a in apps" :key="a.pkg">
      <div class="row" style="justify-content:space-between">
        <div class="row">
          <b>{{ a.pkg }}</b>
          <span v-if="a.bootEnabled === true" style="color:var(--green)">自启开启</span>
          <span v-else-if="a.bootEnabled === false" style="color:var(--red)">自启关闭</span>
          <span v-else class="muted">状态未知</span>
        </div>
        <button class="btn danger sm" v-if="!a.components.length" @click="toggleApp(a.pkg)">禁用整个应用</button>
      </div>
      <table v-if="a.components.length" style="margin-top:8px">
        <thead><tr><th>自启组件</th><th>状态</th><th style="width:120px">操作</th></tr></thead>
        <tbody>
          <tr v-for="c in a.components" :key="c.component">
            <td class="muted">{{ c.component }}</td>
            <td :style="{ color: c.enabled ? 'var(--green)' : 'var(--red)' }">{{ c.enabled ? '启用' : '禁用' }}</td>
            <td><button class="btn sm" @click="toggle(c, !c.enabled)">{{ c.enabled ? '禁用' : '启用' }}</button></td>
          </tr>
        </tbody>
      </table>
      <div v-else class="muted" style="margin-top:6px">未解析到可单独控制的自启组件（可能由厂商管家管理）。</div>
    </div>
  </div>
</template>

<script setup>
import { ref, onMounted, watch } from 'vue';
import { store, showToast } from '../store';
import { apiGet, apiPost } from '../api';

const apps = ref([]);

async function load() {
  try {
    apps.value = await apiGet(`/autostart/${encodeURIComponent(store.serial)}`);
  } catch (e) { showToast(e.message); }
}
async function toggle(c, enabled) {
  try {
    await apiPost(`/autostart/${encodeURIComponent(store.serial)}/toggle`, { component: c.component, enabled });
    c.enabled = enabled;
  } catch (e) { showToast(e.message); }
}
async function toggleApp(pkg) {
  if (!confirm(`禁用应用 ${pkg}（含其所有组件）？可再次启用恢复`)) return;
  try {
    await apiPost(`/autostart/${encodeURIComponent(store.serial)}/toggle`, { component: pkg, enabled: false });
    showToast('已禁用 ' + pkg);
    load();
  } catch (e) { showToast(e.message); }
}

watch(() => store.serial, () => load());
onMounted(() => { if (store.serial) load(); });
</script>
