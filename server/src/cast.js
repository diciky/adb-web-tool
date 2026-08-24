const dgram = require('dgram');
const express = require('express');
const os = require('os');
const config = require('./config');
const { bus } = require('./ws');

const UUID = 'adb-web-cast-0001';
const FRIENDLY = 'ADB Web 投屏';
const ST = 'urn:schemas-upnp-org:device:MediaRenderer:1';
const USN = `uuid:${UUID}::${ST}`;

let hostIp = '127.0.0.1';
let serverPort = config.PORT;

function getLanIp() {
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const i of ifaces[name]) {
      if (i.internal) continue;
      if (i.family !== 'IPv4' && i.family !== 4) continue;
      if (i.address.startsWith('169.254.')) continue;
      if (i.address.startsWith('172.')) continue;
      return i.address;
    }
  }
  return '127.0.0.1';
}

function deviceDescription() {
  return `<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>${ST}</deviceType>
    <friendlyName>${FRIENDLY}</friendlyName>
    <manufacturer>adb-web-tool</manufacturer>
    <modelName>ADB Web Cast</modelName>
    <modelNumber>1.0</modelNumber>
    <UDN>uuid:${UUID}</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/cast/control</controlURL>
        <eventSubURL>/cast/event</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/cast/control</controlURL>
        <eventSubURL>/cast/event</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <controlURL>/cast/control</controlURL>
        <eventSubURL>/cast/event</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>`;
}

function serviceDescription() {
  const actions = [
    'SetAVTransportURI', 'GetMediaInfo', 'GetTransportInfo', 'GetPositionInfo',
    'Play', 'Pause', 'Stop', 'Seek', 'SetPlayMode', 'GetCurrentTransportActions',
  ];
  const avt = actions
    .map(
      (a) => `<action><name>${a}</name><argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList></action>`
    )
    .join('');
  return `<?xml version="1.0" encoding="utf-8"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>${avt}</actionList>
  <serviceStateTable></serviceStateTable>
</scpd>`;
}

function soapResponse(action, body) {
  return `<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:${action}Response xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">${body || ''}</u:${action}Response></s:Body>
</s:Envelope>`;
}

function parseArg(xml, name) {
  const m = xml.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`));
  return m ? m[1] : '';
}

function handleSoap(req, res) {
  let xml = '';
  req.on('data', (c) => (xml += c));
  req.on('end', () => {
    const actionMatch = xml.match(/<(\w+:)?(SetAVTransportURI|GetMediaInfo|GetTransportInfo|GetPositionInfo|Play|Pause|Stop|Seek|SetPlayMode|GetCurrentTransportActions)\b/);
    const action = actionMatch ? actionMatch[2] : '';
    console.log(`[cast] SOAP ${action}`);
    try {
      if (action === 'SetAVTransportURI') {
        const uri = parseArg(xml, 'CurrentURI');
        const meta = parseArg(xml, 'CurrentURIMetaData');
        const titleMatch = meta.match(/<dc:title>([\s\S]*?)<\/dc:title>/) || meta.match(/&lt;dc:title&gt;([\s\S]*?)&lt;\/dc:title&gt;/);
        const title = titleMatch ? titleMatch[1] : '';
        bus.emit('cast', { kind: 'cast_uri', uri, title });
        res.set('Content-Type', 'text/xml');
        res.send(soapResponse('SetAVTransportURI', '<InstanceID>0</InstanceID>'));
      } else if (action === 'Play') {
        bus.emit('cast', { kind: 'cast_play' });
        res.set('Content-Type', 'text/xml');
        res.send(soapResponse('Play', '<InstanceID>0</InstanceID><Speed>1</Speed>'));
      } else if (action === 'Pause') {
        bus.emit('cast', { kind: 'cast_pause' });
        res.set('Content-Type', 'text/xml');
        res.send(soapResponse('Pause', '<InstanceID>0</InstanceID>'));
      } else if (action === 'Stop') {
        bus.emit('cast', { kind: 'cast_stop' });
        res.set('Content-Type', 'text/xml');
        res.send(soapResponse('Stop', '<InstanceID>0</InstanceID>'));
      } else {
        res.set('Content-Type', 'text/xml');
        res.send(soapResponse(action || 'NoAction', '<InstanceID>0</InstanceID>'));
      }
    } catch (e) {
      res.status(500).send('error');
    }
  });
}

function buildSsdpResponse() {
  const loc = `http://${hostIp}:${serverPort}/cast/dd`;
  return [
    'HTTP/1.1 200 OK',
    'CACHE-CONTROL: max-age=1800',
    'EXT:',
    `LOCATION: ${loc}`,
    'SERVER: adb-web-tool/1.0 UPnP/1.0',
    `ST: ${ST}`,
    `USN: ${USN}`,
    '',
    '',
  ].join('\r\n');
}

function buildNotify() {
  const loc = `http://${hostIp}:${serverPort}/cast/dd`;
  return [
    'NOTIFY * HTTP/1.1',
    'HOST: 239.255.255.250:1900',
    'CACHE-CONTROL: max-age=1800',
    `LOCATION: ${loc}`,
    'NTS: ssdp:alive',
    `NT: ${ST}`,
    `USN: ${USN}`,
    '',
    '',
  ].join('\r\n');
}

function startSsdp() {
  const sock = dgram.createSocket('udp4');
  sock.on('error', (e) => console.warn('[cast] SSDP 错误(可忽略):', e.message));
  sock.on('message', (msg, rinfo) => {
    const m = msg.toString();
    if (m.includes('M-SEARCH') && (m.includes('MediaRenderer') || m.includes('ssdp:all') || m.includes('upnp:rootdevice'))) {
      const resp = buildSsdpResponse();
      try { sock.send(resp, 0, resp.length, rinfo.port, rinfo.address); } catch (e) {}
    }
  });
  sock.bind(1900, () => {
    try { sock.setBroadcast(true); } catch (e) {}
    try { sock.addMembership('239.255.255.250'); } catch (e) {}
    const notify = buildNotify();
    try { sock.send(notify, 0, notify.length, 1900, '239.255.255.250'); } catch (e) {}
    setInterval(() => {
      try { sock.send(notify, 0, notify.length, 1900, '239.255.255.250'); } catch (e) {}
    }, 1800);
    console.log('[cast] SSDP 已启动，投屏接收端名称:', FRIENDLY);
  });
}

const router = express.Router();
router.get('/dd', (req, res) => res.type('text/xml').send(deviceDescription()));
router.get('/scd', (req, res) => res.type('text/xml').send(serviceDescription()));
router.post('/control', handleSoap);
router.get('/event', (req, res) => { res.status(200).end(); });

function mount(app) {
  hostIp = getLanIp();
  serverPort = config.PORT;
  app.use('/cast', router);
  startSsdp();
}

module.exports = { mount };
