const express = require('express');
const http = require('http');
const path = require('path');
const fs = require('fs');
const cors = require('cors');
const config = require('./config');
const adb = require('./adb');
const ws = require('./ws');
const scheduler = require('./scheduler');

for (const dir of [config.DATA_DIR, config.UPLOAD_DIR, config.CACHE_DIR]) {
  fs.mkdirSync(dir, { recursive: true });
}

const app = express();
app.use(cors());
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

if (config.ACCESS_TOKEN) {
  const check = (req, res, next) => {
    const token = req.headers['x-access-token'] || req.query.token;
    if (token !== config.ACCESS_TOKEN) {
      return res.status(401).json({ error: '未授权' });
    }
    next();
  };
  app.use('/api', check);
  app.use('/cache', (req, res, next) => {
    const token = req.query.token;
    if (token !== config.ACCESS_TOKEN) return res.status(401).end();
    next();
  });
}

app.use('/cache', express.static(config.CACHE_DIR));
app.use('/api', require('./routes/devices'));
app.use('/api', require('./routes/apps'));
app.use('/api', require('./routes/install'));
app.use('/api', require('./routes/files'));
app.use('/api', require('./routes/tools'));
app.use('/api', require('./routes/mirror'));
app.use('/api', require('./routes/health'));
app.use('/api', require('./routes/nettest'));
app.use('/api', require('./routes/autostart'));
app.use('/api', require('./routes/batch'));

const dist = path.resolve(__dirname, '..', '..', 'web', 'dist');
if (fs.existsSync(dist)) {
  app.use(express.static(dist));
  app.get('*', (req, res) => res.sendFile(path.join(dist, 'index.html')));
}

app.use((err, req, res, next) => {
  res.status(500).json({ error: err.message });
});

const server = http.createServer(app);
ws.attach(server);

adb.ensureServer().then((ok) => {
  if (ok) console.log('[adb] adb 守护进程已就绪');
  else console.warn('[adb] 未检测到 adb 守护进程，请确认已安装 platform-tools');
});

server.listen(config.PORT, config.HOST, () => {
  scheduler.start();
  console.log(`[server] ADB Web 工具已启动: http://${config.HOST}:${config.PORT}`);
  console.log(`[server] 数据目录: ${config.DATA_DIR}`);
});
