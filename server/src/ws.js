const { WebSocketServer } = require('ws');
const events = require('events');
const adb = require('./adb');

const bus = new events.EventEmitter();

const logcatStreams = new Map();
const shellStreams = new Map();

function broadcast(msg) {
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

function attach(server) {
  wss = new WebSocketServer({ server, path: '/ws' });

  bus.on('task', (msg) => broadcast({ type: 'task', ...msg }));
  bus.on('scan', (msg) => broadcast({ type: 'scan_progress', ...msg }));
  bus.on('scan_done', (msg) => broadcast({ type: 'scan_done', ...msg }));

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
      }
      break;
    case 'unsubscribe':
      ws._subs.delete(`${msg.channel}:${msg.serial}`);
      if (msg.channel === 'logcat') {
        stopLogcat(msg.serial, ws);
      }
      break;
    case 'shell':
      sendShell(ws, msg.serial, msg.data);
      break;
    case 'shell_kill':
      stopShell(ws);
      break;
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
