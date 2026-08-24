<template>
  <div class="card">
    <h3>投屏发送端</h3>
    <p class="muted">在手机/电脑浏览器打开本页，选择要投的画面，电视端「投屏接收」页会实时显示（WebRTC）。PC/安卓可选「投屏幕/窗口」；iOS 仅支持摄像头。</p>
    <div class="row">
      <button class="btn" @click="shareScreen">投屏幕/窗口</button>
      <button class="btn" @click="shareCamera">投摄像头</button>
      <button class="btn danger" @click="stop">停止</button>
    </div>
    <video ref="local" class="cast-video" autoplay playsinline muted style="margin-top:8px"></video>
    <div class="cast-status">状态：{{ status }}</div>
  </div>
</template>

<script setup>
import { ref, onUnmounted } from 'vue';
import { showToast } from '../store';

const local = ref(null);
const status = ref('空闲');
let ws = null;
let pc = null;
let stream = null;
const iceServers = [{ urls: 'stun:stun.l.google.com:19302' }];

function sendMsg(m) { if (ws && ws.readyState === ws.OPEN) ws.send(JSON.stringify(m)); }
function openWs() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const token = new URLSearchParams(location.search).get('token') || '';
  ws = new WebSocket(`${proto}://${location.host}/ws${token ? '?token=' + token : ''}`);
  ws.onmessage = (e) => {
    let m; try { m = JSON.parse(e.data); } catch (_) { return; }
    if (m.type === 'cast_signal') onSignal(m);
  };
}
async function start(getMedia) {
  stop();
  try { stream = await getMedia(); } catch (e) { showToast('无法获取画面: ' + e.message); return; }
  if (local.value) local.value.srcObject = stream;
  openWs();
  pc = new RTCPeerConnection({ iceServers });
  stream.getTracks().forEach((t) => pc.addTrack(t, stream));
  pc.onicecandidate = (e) => { if (e.candidate) sendMsg({ type: 'cast_signal', from: 'sender', data: { candidate: e.candidate } }); };
  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  sendMsg({ type: 'cast_signal', from: 'sender', data: { sdp: pc.localDescription } });
  status.value = '发送中（等待接收端）';
}
function shareScreen() { start(navigator.mediaDevices.getDisplayMedia({ video: true, audio: false })); }
function shareCamera() { start(navigator.mediaDevices.getUserMedia({ video: true, audio: false })); }
function onSignal(m) {
  const d = m.data || {};
  if (d.sdp && d.sdp.type === 'answer') {
    if (pc) pc.setRemoteDescription(new RTCSessionDescription(d.sdp)).catch((e) => showToast('' + e.message));
  } else if (d.candidate) {
    if (pc) pc.addIceCandidate(new RTCIceCandidate(d.candidate)).catch(() => {});
  }
}
function stop() {
  if (stream) { stream.getTracks().forEach((t) => t.stop()); stream = null; }
  if (pc) { try { pc.close(); } catch (_) {} pc = null; }
  if (ws) { try { ws.close(); } catch (_) {} ws = null; }
  if (local.value) local.value.srcObject = null;
  status.value = '空闲';
}
onUnmounted(stop);
</script>

<style scoped>
.cast-video { width: 100%; max-height: 60vh; background: #000; border-radius: 8px; }
.cast-status { margin-top: 6px; }
</style>
