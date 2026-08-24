const { WebSocketServer } = require('ws');
const events = require('events');
const { spawn } = require('child_process');
const adb = require('./adb');
const config = require('./config');

const bus = new events.EventEmitter();

const logcatStreams = new Map();
const shellStreams = new Map();
const h264Streams = new Map();

function startMirrorH264(ws, serial) {
  if (ws._h264Key) return;
  const proc = spawn(config.ADB_BIN, [
    '-s', serial,
    'exec-out', 'screenrecord',
    '--output-format=h264',
    '--bit-rate', '4000000',
    '--size', '960x540',
    '-',
  ]);
  ws._h264Key = `h264:${serial}`;
  proc.stdout.on('data', (buf) => {
    if (ws.readyState === ws.OPEN) {
      try { ws.send(buf); } catch (_) {}
    }
  });
  proc.on('error', (err) => {
    try { ws.send(JSON.stringify({ type: 'mirror_h264_error', message: err.message || 'screenrecord 启动失败' })); } catch (_) {}
  });
  proc.on('close', () => {
    try { ws.send(JSON.stringify({ type: 'mirror_h264_end' })); } catch (_) {}
  });
  h264Streams.set(ws._h264Key, proc);
}

function stopMirrorH264(ws) {
  if (ws._h264Key) {
    const proc = h264Streams.get(ws._h264Key);
    if (proc) {
      try { proc.kill('SIGKILL'); } catch (_) {}
      h264Streams.delete(ws._h264Key);
    }
    ws._h264Key = null;
  }
}

function broadcast(msg) {
  if (!wss) return;
  const data = JSON.stringify(msg);
  for (const ws of wss.clients) {
    if (ws.readyState === ws.OPEN) {
      ws.send(data);
    }
  }
}

function broadcastTo(serial, channel, msg) {
  const data = JSON.stringify(msg);
  for (const ws of wss.clients) {
    if (ws.readyState === ws.OPEN && ws._subs && ws._subs.has(`${channel}:${serial}`)) {
      ws.send(data);
    }
  }
}

let wss;
let senderWs = null;
let receiverWs = null;

function attach(server) {
  wss = new WebSocketServer({ server, path: '/ws' });

  bus.on('task', (msg) => broadcast({ type: 'task', ...msg }));
  bus.on('scan', (msg) => broadcast({ type: 'scan_progress', ...msg }));
  bus.on('scan_done', (msg) => broadcast({ type: 'scan_done', ...msg }));
  bus.on('log', (msg) => broadcast({ type: 'log', ...msg }));
  bus.on('cast', (msg) => broadcast({ type: 'cast', ...msg }));

  wss.on('connection', (ws) => {
    ws._subs = new Set();

    ws.on('message', async (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch (e) {
        return;
      }
      try {
        await handleMessage(ws, msg);
      } catch (e) {
        ws.send(JSON.stringify({ type: 'error', message: e.message }));
      }
    });

    ws.on('close', () => {
      if (ws._shellProc) {
        try { ws._shellProc.end(); } catch (e) {}
      }
      if (ws._h264Key) stopMirrorH264(ws);
      if (ws === senderWs) senderWs = null;
      if (ws === receiverWs) receiverWs = null;
      delete shellStreams[ws._id];
    });
  });

  return wss;
}

async function handleMessage(ws, msg) {
  const dev = adb.client;
  switch (msg.type) {
    case 'subscribe':
      ws._subs.add(`${msg.channel}:${msg.serial}`);
      if (msg.channel === 'logcat') {
        startLogcat(ws, msg.serial);
      } else if (msg.channel === 'mirror_h264') {
        startMirrorH264(ws, msg.serial);
      }
      break;
    case 'unsubscribe':
      ws._subs.delete(`${msg.channel}:${msg.serial}`);
      if (msg.channel === 'logcat') {
        stopLogcat(msg.serial, ws);
      } else if (msg.channel === 'mirror_h264') {
        stopMirrorH264(ws);
      }
      break;
    case 'shell':
      sendShell(ws, msg.serial, msg.data);
      break;
    case 'shell_kill':
      stopShell(ws);
      break;
    case 'cast_signal': {
      const from = msg.from;
      if (from === 'sender') senderWs = ws;
      else if (from === 'receiver') receiverWs = ws;
      const target = from === 'sender' ? receiverWs : senderWs;
      if (target && target !== ws && target.readyState === target.OPEN) {
        target.send(JSON.stringify(msg));
      }
      break;
    }
    default:
      break;
  }
}

function startLogcat(ws, serial) {
  const key = `logcat:${serial}`;
  let entry = logcatStreams.get(key);
  if (!entry) {
    const stream = adb.getDevice(serial).openLogcat();
    entry = { stream, subscribers: new Set() };
    stream.on('entry', (entryObj) => {
      broadcastTo(serial, 'logcat', {
        type: 'logcat',
        serial,
        entry: {
          time: entryObj.time ? entryObj.time.toString() : '',
          pid: entryObj.pid,
          tid: entryObj.tid,
          level: entryObj.priority,
          tag: entryObj.tag,
          message: entryObj.message,
        },
      });
    });
    stream.on('error', (err) => {
      broadcastTo(serial, 'logcat', { type: 'logcat_error', serial, message: err.message });
    });
    entry.subscribers.add(ws);
    logcatStreams.set(key, entry);
  } else {
    entry.subscribers.add(ws);
  }
}

function stopLogcat(serial, ws) {
  const key = `logcat:${serial}`;
  const entry = logcatStreams.get(key);
  if (entry) {
    entry.subscribers.delete(ws);
    if (entry.subscribers.size === 0) {
      try { entry.stream.end(); } catch (e) {}
      logcatStreams.delete(key);
    }
  }
}

function sendShell(ws, serial, data) {
  let proc = shellStreams.get(ws._id);
  if (!proc) {
    proc = adb.getDevice(serial).shell('');
    proc.on('data', (buf) => {
      ws.send(JSON.stringify({ type: 'shell_out', serial, data: buf.toString('utf8', 0, buf.length) }));
    });
    proc.on('error', (err) => {
      ws.send(JSON.stringify({ type: 'shell_err', serial, data: err.message }));
    });
    proc.on('end', () => {
      ws.send(JSON.stringify({ type: 'shell_exit', serial }));
      ws._shellProc = null;
      if (ws._id) shellStreams.delete(ws._id);
    });
    ws._shellProc = proc;
    ws._id = ws._id || String(Math.random());
    ws._shellSerial = serial;
    shellStreams.set(ws._id, proc);
  }
  proc.write(data);
}

function stopShell(ws) {
  if (ws._shellProc) {
    try { ws._shellProc.end(); } catch (e) {}
    ws._shellProc = null;
  }
}

module.exports = { attach, bus, broadcast };
