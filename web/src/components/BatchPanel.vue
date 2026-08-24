<template>
  <div v-if="!store.devices.length" class="card muted">请先连接设备。</div>
  <div v-else>
    <div class="card">
      <h3>批量任务</h3>
      <div class="row"><span class="muted">目标设备：</span>
        <label v-for="d in store.devices" :key="d.serial" class="row" style="margin-right:12px">
          <input type="checkbox" :value="d.serial" v-model="targets" /> {{ d.serial }}
        </label>
      </div>
      <div class="row" style="margin-top:8px">
        <select v-model="action">
          <option value="reboot">重启</option>
          <option value="shutdown">关机</option>
          <option value="recovery">进入 Recovery</option>
          <option value="wake">唤醒</option>
          <option value="sleep">熄屏</option>
          <option value="install">安装 APK</option>
          <option value="uninstall">卸载</option>
          <option value="clearData">清除数据</option>
          <option value="forceStop">强制停止</option>
          <option value="launch">启动应用</option>
        </select>
        <input v-if="needsPkg" v-model="pkg" placeholder="包名" style="min-width:200px" />
        <input v-if="action==='install'" type="file" accept=".apk" @change="uploadApk" />
        <span v-if="action==='install' && apkName" class="muted">{{ apkName }}</span>
        <button class="btn" @click="runBatch" :disabled="!targets.length">执行</button>
      </div>
      <table v-if="results.length" style="margin-top:10px">
        <thead><tr><th>设备</th><th>结果</th><th>信息</th></tr></thead>
        <tbody>
          <tr v-for="r in results" :key="r.serial">
            <td>{{ r.serial }}</td>
            <td :style="{ color: r.ok ? 'var(--green)' : 'var(--red)' }">{{ r.ok ? '成功' : '失败' }}</td>
            <td class="muted">{{ r.message || '' }}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="card">
      <h3>定时任务</h3>
      <div class="row">
        <input v-model="job.name" placeholder="任务名" style="width:140px" />
        <select v-model="job.action">
          <option value="reboot">重启</option>
          <option value="shutdown">关机</option>
          <option value="wake">唤醒</option>
          <option value="sleep">熄屏</option>
          <option value="uninstall">卸载</option>
          <option value="clearData">清除数据</option>
          <option value="forceStop">强制停止</option>
        </select>
        <input v-if="jobNeedsPkg" v-model="job.pkg" placeholder="包名" style="min-width:180px" />
        <select v-model="job.mode">
          <option value="interval">固定间隔</option>
          <option value="cron">Cron 表达式</option>
        </select>
        <input v-if="job.mode==='interval'" type="number" v-model.number="job.intervalSec" placeholder="秒" style="width:90px" />
        <input v-else v-model="job.cron" placeholder="分 时 日 月 周" style="width:160px" />
        <button class="btn" @click="addJob">添加定时</button>
      </div>
      <div class="row" style="margin-top:6px">
        <span class="muted">目标：</span>
        <label v-for="d in store.devices" :key="d.serial" class="row" style="margin-right:10px">
          <input type="checkbox" :value="d.serial" v-model="job.targets" /> {{ d.serial }}
        </label>
      </div>
    </div>

    <div class="card" v-if="schedules.length">
      <table>
        <thead><tr><th>名称</th><th>动作</th><th>目标</th><th>下次执行</th><th>最近结果</th><th style="width:160px">操作</th></tr></thead>
        <tbody>
          <tr v-for="j in schedules" :key="j.id">
            <td>{{ j.name }}</td>
            <td>{{ j.action }}</td>
            <td class="muted">{{ (j.targets || []).join(', ') }}</td>
            <td class="muted">{{ j.nextRun ? new Date(j.nextRun).toLocaleString() : '-' }}</td>
            <td class="muted">{{ j.lastResult ? (j.lastResult.filter(r=>r.ok).length + '/' + j.lastResult.length + ' 成功') : '-' }}</td>
            <td class="row">
              <button class="btn ghost sm" @click="runNow(j.id)">立即执行</button>
              <button class="btn danger sm" @click="delJob(j.id)">删除</button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onMounted } from 'vue';
import { store, showToast } from '../store';
import { apiGet, apiPost, apiUpload } from '../api';

const targets = ref([]);
const action = ref('reboot');
const pkg = ref('');
const apkPath = ref('');
const apkName = ref('');
const results = ref([]);

const needsPkg = computed(() => ['uninstall', 'clearData', 'forceStop', 'launch'].includes(action.value));

async function uploadApk(e) {
  const f = e.target.files[0];
  if (!f) return;
  const form = new FormData();
  form.append('file', f);
  try {
    const r = await apiUpload('/shared-upload', form);
    apkPath.value = r.path; apkName.value = r.name;
  } catch (err) { showToast(err.message); }
}
async function runBatch() {
  const params = {};
  if (action.value === 'install') { if (!apkPath.value) return showToast('请先选择 APK'); params.apkPath = apkPath.value; }
  else if (needsPkg.value) { if (!pkg.value) return showToast('请输入包名'); params.pkg = pkg.value; }
  try {
    const r = await apiPost('/batch/run', { action: action.value, targets: targets.value, params });
    results.value = r.results;
  } catch (e) { showToast(e.message); }
}

const schedules = ref([]);
const job = ref({ name: '', action: 'reboot', targets: [], mode: 'interval', intervalSec: 3600, cron: '0 3 * * *', pkg: '' });
const jobNeedsPkg = computed(() => ['uninstall', 'clearData', 'forceStop'].includes(job.value.action));

async function loadSchedules() {
  try { schedules.value = await apiGet('/schedules'); } catch (e) {}
}
async function addJob() {
  const j = job.value;
  if (!j.targets.length) return showToast('请选择目标设备');
  const body = { name: j.name || j.action, action: j.action, targets: j.targets };
  if (jobNeedsPkg.value) body.params = { pkg: j.pkg };
  if (j.mode === 'interval') body.intervalSec = j.intervalSec;
  else body.cron = j.cron;
  try { await apiPost('/schedules', body); showToast('已添加定时任务'); loadSchedules(); } catch (e) { showToast(e.message); }
}
async function runNow(id) {
  try { await apiPost(`/schedules/${id}/run`, {}); showToast('已触发执行'); loadSchedules(); } catch (e) { showToast(e.message); }
}
async function delJob(id) {
  const token = new URLSearchParams(location.search).get('token') || '';
  try {
    await fetch(`/api/schedules/${id}?token=${token}`, { method: 'DELETE' });
    loadSchedules();
  } catch (e) { showToast(e.message); }
}

onMounted(loadSchedules);
</script>
