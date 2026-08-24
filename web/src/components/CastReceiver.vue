<template>
  <div class="card">
    <h3>投屏接收端（在电视上运行）</h3>
    <p class="muted">此页即投屏接收端，应运行在电视/大屏上。手机或电脑打开「投屏发送」页，选择屏幕或摄像头后，本页会经 WebRTC 直接接收并播放（媒体点对点，不经过服务端）。服务端仅做信令中转。</p>
    <div class="cast-status">状态：{{ status }}</div>
    <video ref="video" class="cast-video" autoplay playsinline controls></video>
    <div class="row" style="margin-top:8px">
      <button class="btn ghost sm" @click="stopAll">停止</button>
    </div>
  </div>
</template>

<script setup>
import { ref, onUnmounted } from 'vue';
import { showToast } from '../store';

const video = ref(null);
const status = ref('等待投屏（请在手机/电脑打开「投屏发送」）…');
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
    if (m.type === 'cast_signal') onSignal(m);
  };
  ws.onclose = () => { status.value = '连接断开'; };
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
