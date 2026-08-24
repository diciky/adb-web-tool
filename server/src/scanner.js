const net = require('net');
const os = require('os');
const config = require('./config');

function detectSubnets() {
  const subs = new Set();
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name]) {
      if (iface.internal) continue;
      if (iface.family !== 'IPv4' && iface.family !== 4) continue;
      const parts = iface.address.split('.');
      const netBase = `${parts[0]}.${parts[1]}.${parts[2]}.0/24`;
      subs.add(netBase);
    }
  }
  config.SUBNETS.forEach((s) => subs.add(s));
  return Array.from(subs);
}

function parseSubnet(subnet) {
  const [ip, bits] = subnet.split('/');
  const mask = bits ? parseInt(bits, 10) : 24;
  const a = ip.split('.').map(Number);
  const base = ((a[0] << 24) | (a[1] << 16) | (a[2] << 8) | a[3]) >>> 0;
  const hostBits = 32 - mask;
  const start = base & (0xffffffff << hostBits);
  const count = Math.pow(2, hostBits);
  const ips = [];
  for (let i = 0; i < count; i++) {
    const n = (start + i) >>> 0;
    const o1 = (n >>> 24) & 0xff;
    const o2 = (n >>> 16) & 0xff;
    const o3 = (n >>> 8) & 0xff;
    const o4 = n & 0xff;
    ips.push(`${o1}.${o2}.${o3}.${o4}`);
  }
  return ips;
}

function probe(ip, port, timeout) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let done = false;
    const finish = (open) => {
      if (done) return;
      done = true;
      try { socket.destroy(); } catch (e) {}
      resolve(open);
    };
    socket.setTimeout(timeout);
    socket.once('connect', () => finish(true));
    socket.once('timeout', () => finish(false));
    socket.once('error', () => finish(false));
    socket.connect(port, ip);
  });
}

async function scanSubnet(subnet, ports, bus) {
  const ips = parseSubnet(subnet);
  const timeout = 350;
  const concurrency = 256;
  let idx = 0;
  let found = 0;

  async function worker() {
    while (idx < ips.length) {
      const ip = ips[idx++];
      for (const port of ports) {
        const open = await probe(ip, port, timeout);
        if (open) {
          found++;
          bus.emit('scan', { ip, port, serial: `${ip}:${port}` });
        }
      }
    }
  }

  const workers = [];
  for (let i = 0; i < concurrency; i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  bus.emit('scan_done', { subnet, total: found });
  return found;
}

function startScan(subnet, bus) {
  const target = subnet || detectSubnets()[0];
  if (!target) {
    bus.emit('scan_done', { subnet: '', total: 0 });
    return Promise.resolve(0);
  }
  const ports = config.SCAN_PORTS;
  return scanSubnet(target, ports, bus);
}

module.exports = { detectSubnets, startScan, scanSubnet };
