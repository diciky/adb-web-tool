<template>
  <div class="card">
    <h3>投屏接收端</h3>
    <p class="muted">在安卓TV/电脑浏览器打开本页即用。安卓与部分PC可用系统原生「投屏/投射」发现「{{ friendly }}」并推送视频；iOS 或不支持 DLNA 时，用「投屏发送」页经 WebRTC 实时传屏。</p>
    <div class="cast-status">状态：{{ status }}<span v-if="title"> · {{ title }}</span></div>
    <video ref="video" class="cast-video" autoplay playsinline controls></video>
    <div class="row" style="margin-top:8px">
      <button class="btn ghost sm" @click="stopAll">停止</button>
    </div>
  </div>
</template>

<script setup>
import { ref, onUnmounted } from 'vue';
import { showToast } from '../store';

const friendly = 'ADB Web 投屏';
const video = ref(null);
const status = ref('等待投屏…');
const title = ref('');
let ws = null;
let pc = null;
const iceServers = [{ urls: 'stun:stun.l.google.com:19302' }];

function sendMsg(m) { if (ws && ws.readyState === ws.OPEN) ws.send(JSON.stringify(m)); }

function openWs() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const token = new URLSearchParams(location.search).get('token') || '';
  ws = new WebSocket(`${proto}://${location.host}/ws${token ? '?token=' + token : ''}`);
  ws.onopen = () => { sendMsg({ type: 'cast_signal', from: 'receiver' }); };
  ws.onmessage = (e) => {
    let m; try { m = JSON.parse(e.data); } catch (_) { return; }
    if (m.type === 'cast') onCast(m);
    else if (m.type === 'cast_signal') onSignal(m);
  };
  ws.onclose = () => { status.value = '连接断开'; };
}
function onCast(m) {
  const v = video.value;
  if (m.kind === 'cast_uri') {
    title.value = m.title || '';
    status.value = '接收中';
    if (v) { if (pc) { try { pc.close(); } catch (_) {} pc = null; } v.srcObject = null; v.src = m.uri; v.play().catch(() => {}); }
  } else if (m.kind === 'cast_play') {
    status.value = '播放中'; if (v) v.play().catch(() => {});
  } else if (m.kind === 'cast_pause') {
    status.value = '暂停'; if (v) v.pause();
  } else if (m.kind === 'cast_stop') {
    status.value = '空闲'; if (v) { v.pause(); v.removeAttribute('src'); v.load(); }
  }
}
function onSignal(m) {
  const d = m.data || {};
  if (d.sdp && d.sdp.type === 'offer') {
    pc = new RTCPeerConnection({ iceServers });
    pc.ontrack = (e) => { const v = video.value; if (v) { v.srcObject = e.streams[0]; v.play().catch(() => {}); } status.value = 'WebRTC 播放中'; };
    pc.onicecandidate = (e) => { if (e.candidate) sendMsg({ type: 'cast_signal', from: 'receiver', data: { candidate: e.candidate } }); };
    pc.setRemoteDescription(new RTCSessionDescription(d.sdp))
      .then(() => pc.createAnswer())
      .then((a) => pc.setLocalDescription(a))
      .then(() => sendMsg({ type: 'cast_signal', from: 'receiver', data: { sdp: pc.localDescription } }))
      .catch((err) => showToast('WebRTC 错误: ' + err.message));
  } else if (d.candidate) {
    if (pc) pc.addIceCandidate(new RTCIceCandidate(d.candidate)).catch(() => {});
  }
}
function stopAll() {
  if (pc) { try { pc.close(); } catch (_) {} pc = null; }
  if (ws) { try { ws.close(); } catch (_) {} ws = null; }
  status.value = '空闲';
}
onUnmounted(stopAll);
openWs();
</script>

<style scoped>
.cast-video { width: 100%; max-height: 70vh; background: #000; border-radius: 8px; margin-top: 8px; }
.cast-status { margin: 6px 0; }
</style>
