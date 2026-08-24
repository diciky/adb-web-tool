<template>
  <div>
    <div v-if="!store.devices.length" class="card muted">请先连接至少一个设备。</div>
    <div v-else class="card">
      <h3>选择安装目标</h3>
      <div class="row">
        <label v-for="d in store.devices" :key="d.serial" class="row" style="margin-right:14px">
          <input type="checkbox" :value="d.serial" v-model="targets" />
          {{ d.serial }}
        </label>
      </div>
      <p class="muted">提示：安卓 TV 需开启「未知来源应用」安装权限；首次连接需先在电视上确认调试授权。</p>

      <div
        class="dropzone"
        :class="{ over: over }"
        @dragover.prevent="over = true"
        @dragleave.prevent="over = false"
        @drop.prevent="onDrop"
        @click="$refs.file.click()"
      >
        拖拽 APK 文件到此处，或点击选择<br />
        <span class="muted">支持多选、自动依次安装到所选设备</span>
        <input ref="file" type="file" accept=".apk" multiple hidden @change="onPick" />
      </div>
    </div>

    <div class="card" v-if="jobList.length">
      <h3>任务进度</h3>
      <div v-for="t in jobList" :key="t.id" style="margin:8px 0">
        <div class="row" style="justify-content:space-between">
          <span>{{ t.message || (t.kind === 'install' ? '安装' : '推送') }} · {{ t.serial }}</span>
          <span :style="{color: t.error ? 'var(--red)' : t.done ? 'var(--green)' : 'var(--text)'}">
            {{ t.error ? '失败' : t.done ? '完成' : t.percent + '%' }}
          </span>
        </div>
        <div class="progress"><span :style="{width: (t.error ? 100 : t.percent) + '%', background: t.error ? 'var(--red)' : ''}"></span></div>
        <div v-if="t.error" class="muted" style="color:var(--red)">{{ t.error }}</div>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from 'vue';
import { store, showToast } from '../store';
import { apiUpload } from '../api';

const over = ref(false);
const file = ref(null);
const targets = ref([]);

if (store.serial) targets.value = [store.serial];

const jobList = computed(() => Object.values(store.tasks).filter((t) => t.kind === 'install'));

async function installFile(f) {
  const myTargets = targets.value.length ? targets.value : (store.serial ? [store.serial] : []);
  if (!myTargets.length) { showToast('请选择安装目标'); return; }
  const deviceOk = myTargets.filter((s) => store.devices.find((d) => d.serial === s));
  for (const s of deviceOk) {
    const jobId = `install_${Date.now()}_${Math.random().toString(36).slice(2, 6)}`;
    const form = new FormData();
    form.append('apk', f);
    form.append('jobId', jobId);
    try {
      await apiUpload(`/install/${encodeURIComponent(s)}?jobId=${jobId}`, form);
    } catch (e) {
      showToast(`${f.name} → ${s} 失败: ${e.message}`);
    }
  }
}

function onPick(e) {
  for (const f of e.target.files) installFile(f);
  e.target.value = '';
}
function onDrop(e) {
  over.value = false;
  for (const f of e.dataTransfer.files) installFile(f);
}
</script>
