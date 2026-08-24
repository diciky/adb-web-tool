<template>
  <canvas ref="cv" :width="width" :height="height" :style="{ width: '100%', height: height + 'px' }"></canvas>
</template>

<script setup>
import { ref, watch, onMounted } from 'vue';

const props = defineProps({
  series: { type: Array, default: () => [] },
  max: { type: Number, default: 100 },
  height: { type: Number, default: 160 },
  width: { type: Number, default: 600 },
});

const cv = ref(null);

function draw() {
  const ctx = cv.value.getContext('2d');
  const w = props.width;
  const h = props.height;
  ctx.clearRect(0, 0, w, h);
  ctx.fillStyle = '#0f1419';
  ctx.fillRect(0, 0, w, h);
  ctx.strokeStyle = '#2f3a47';
  ctx.lineWidth = 1;
  for (let i = 0; i <= 4; i++) {
    const y = (h / 4) * i;
    ctx.beginPath();
    ctx.moveTo(0, y);
    ctx.lineTo(w, y);
    ctx.stroke();
  }
  const pad = 4;
  for (const s of props.series) {
    const data = s.data || [];
    if (data.length < 2) continue;
    ctx.strokeStyle = s.color;
    ctx.lineWidth = 2;
    ctx.beginPath();
    const step = (w - pad * 2) / (data.length - 1);
    data.forEach((v, i) => {
      const x = pad + step * i;
      const y = h - pad - (Math.min(v, props.max) / props.max) * (h - pad * 2);
      if (i === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    });
    ctx.stroke();
    const last = data[data.length - 1];
    const lx = pad + step * (data.length - 1);
    const ly = h - pad - (Math.min(last, props.max) / props.max) * (h - pad * 2);
    ctx.fillStyle = s.color;
    ctx.beginPath();
    ctx.arc(lx, ly, 3, 0, Math.PI * 2);
    ctx.fill();
  }
}

onMounted(draw);
watch(() => props.series, draw, { deep: true });
</script>
