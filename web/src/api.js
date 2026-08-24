const TOKEN = new URLSearchParams(location.search).get('token') || '';

function authHeaders() {
  const h = { 'Content-Type': 'application/json' };
  if (TOKEN) h['x-access-token'] = TOKEN;
  return h;
}

function queryToken() {
  return TOKEN ? (TOKEN.includes('?') ? TOKEN : `?token=${TOKEN}`) : '';
}

export async function apiGet(path) {
  const res = await fetch(`/api${path}${path.includes('?') ? '&' : '?'}token=${TOKEN}`);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

export async function apiPost(path, body) {
  const res = await fetch(`/api${path}${path.includes('?') ? '&' : '?'}token=${TOKEN}`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(body || {}),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

export async function apiUpload(path, form, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', `/api${path}${path.includes('?') ? '&' : '?'}token=${TOKEN}`);
    if (TOKEN) xhr.setRequestHeader('x-access-token', TOKEN);
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && onProgress) onProgress(Math.round((e.loaded / e.total) * 100));
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        try { resolve(JSON.parse(xhr.responseText)); } catch (e) { resolve({}); }
      } else {
        try { reject(new Error(JSON.parse(xhr.responseText).error || '上传失败')); }
        catch (e) { reject(new Error('上传失败')); }
      }
    };
    xhr.onerror = () => reject(new Error('网络错误'));
    xhr.send(form);
  });
}

export function wsUrl() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  return `${proto}://${location.host}/ws${queryToken()}`;
}

export function downloadUrl(path) {
  return `/api${path}${path.includes('?') ? '&' : '?'}token=${TOKEN}`;
}
