<template>
  <div class="card remote-card">
    <h3>遥控器</h3>
    <p class="muted">模拟真实遥控器，含数字键</p>
    <div class="remote">
      <div class="r-row">
        <button class="rk danger" @click="key(26)">电源</button>
        <button class="rk" @click="key(177)">输入源</button>
        <button class="rk" @click="key(164)">静音</button>
      </div>
      <div class="r-row">
        <button class="rk sm" @click="wake('wake')">唤醒</button>
        <button class="rk sm" @click="wake('sleep')">熄屏</button>
      </div>

      <div class="r-row">
        <button class="rk" @click="key(3)">主页</button>
        <button class="rk" @click="key(82)">菜单</button>
        <button class="rk" @click="key(4)">返回</button>
      </div>

      <div class="dpad">
        <button class="rk up" @click="key(19)">▲</button>
        <button class="rk left" @click="key(21)">◀</button>
        <button class="rk ok" @click="key(23)">OK</button>
        <button class="rk right" @click="key(22)">▶</button>
        <button class="rk down" @click="key(20)">▼</button>
      </div>

      <div class="r-pairs">
        <div class="r-col">
          <button class="rk" @click="key(24)">音量 +</button>
          <button class="rk" @click="key(25)">音量 −</button>
        </div>
        <div class="r-col">
          <button class="rk" @click="key(166)">频道 +</button>
          <button class="rk" @click="key(167)">频道 −</button>
        </div>
      </div>

      <div class="numpad">
        <button class="rk num" v-for="n in 9" :key="n" @click="key(7 + n)">{{ n }}</button>
        <button class="rk num" @click="key(67)">删除</button>
        <button class="rk num" @click="key(7)">0</button>
        <span class="rk num placeholder"></span>
      </div>
    </div>
  </div>
</template>

<script setup>
import { store, showToast } from '../store';
import { apiPost } from '../api';

async function key(code) {
  if (!store.serial) return showToast('请先选择设备');
  try {
    await apiPost(`/tools/${encodeURIComponent(store.serial)}/key`, { code });
  } catch (e) {
    showToast(e.message);
  }
}
async function wake(action) {
  if (!store.serial) return showToast('请先选择设备');
  try {
    await apiPost(`/tools/${encodeURIComponent(store.serial)}/wake`, { action });
  } catch (e) {
    showToast(e.message);
  }
}
</script>

<style scoped>
.remote-card { width: 260px; flex: 0 0 auto; }
.remote { display: flex; flex-direction: column; gap: 10px; align-items: center; }
.r-row { display: flex; gap: 8px; flex-wrap: wrap; justify-content: center; }
.r-pairs { display: flex; gap: 8px; justify-content: center; }
.r-col { display: flex; flex-direction: column; gap: 8px; }
.dpad {
  display: grid;
  grid-template-columns: repeat(3, 60px);
  grid-template-rows: repeat(3, 60px);
  gap: 8px;
}
.dpad .up { grid-area: 1 / 2; }
.dpad .left { grid-area: 2 / 1; }
.dpad .ok { grid-area: 2 / 2; }
.dpad .right { grid-area: 2 / 3; }
.dpad .down { grid-area: 3 / 2; }
.numpad { display: grid; grid-template-columns: repeat(3, 60px); gap: 8px; }
.rk {
  min-width: 60px;
  height: 44px;
  padding: 0 10px;
  border-radius: 10px;
  border: 1px solid var(--border);
  background: #1c2128;
  color: #e6edf3;
  cursor: pointer;
  font-size: 13px;
}
.rk:hover { background: #2a3138; }
.rk:active { transform: scale(0.96); }
.rk.danger { background: #5c1f1f; border-color: #7d2a2a; }
.dpad .rk { height: 60px; }
.rk.num { height: 60px; font-size: 18px; font-weight: 700; }
.rk.sm { min-width: 70px; height: 36px; }
.rk.placeholder { visibility: hidden; }
</style>
