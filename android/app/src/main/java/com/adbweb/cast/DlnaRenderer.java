package com.adbweb.cast;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.MulticastSocket;
import java.net.NetworkInterface;
import java.util.Enumeration;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import fi.iki.elonen.IHTTPSession;
import fi.iki.elonen.NanoHTTPD;

public class DlnaRenderer {
    public interface Listener {
        void onSetUri(String uri, String title);
        void onPlay();
        void onPause();
        void onStop();
    }

    private static final String FRIENDLY = "ADB Web 投屏";
    private static final String UUID = "adb-web-cast-tv";
    private static final String ST = "urn:schemas-upnp-org:device:MediaRenderer:1";
    private static final String USN = "uuid:" + UUID + "::" + ST;
    private static final String AV_NS = "urn:schemas-upnp-org:service:AVTransport:1";

    private final int httpPort;
    private final Listener listener;
    private final Context ctx;
    private String hostIp;
    private HttpServer http;
    private Thread ssdpThread;
    private WifiManager.MulticastLock lock;
    private volatile boolean running = false;

    public DlnaRenderer(Context ctx, int httpPort, Listener listener) {
        this.ctx = ctx;
        this.httpPort = httpPort;
        this.listener = listener;
        this.hostIp = getLanIp();
    }

    public void start() {
        running = true;
        try {
            WifiManager wm = (WifiManager) ctx.getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                lock = wm.createMulticastLock("dlna");
                lock.acquire();
            }
        } catch (Exception e) {
            Log.w("DlnaRenderer", "multicast lock failed", e);
        }
        try {
            http = new HttpServer(httpPort);
            http.start();
        } catch (IOException e) {
            Log.e("DlnaRenderer", "HTTP 启动失败", e);
        }
        ssdpThread = new Thread(this::ssdpLoop);
        ssdpThread.start();
        Log.i("DlnaRenderer", "DLNA 接收端已启动: " + location());
    }

    public void stop() {
        running = false;
        if (http != null) http.stop();
        if (ssdpThread != null) ssdpThread.interrupt();
        if (lock != null && lock.isHeld()) lock.release();
    }

    private String getLanIp() {
        try {
            Enumeration<NetworkInterface> nis = NetworkInterface.getNetworkInterfaces();
            while (nis.hasMoreElements()) {
                NetworkInterface ni = nis.nextElement();
                if (ni.isLoopback() || !ni.isUp()) continue;
                Enumeration<InetAddress> addrs = ni.getInetAddresses();
                while (addrs.hasMoreElements()) {
                    InetAddress a = addrs.nextElement();
                    if (a instanceof java.net.Inet4Address && !a.isLoopbackAddress()) {
                        String h = a.getHostAddress();
                        if (!h.startsWith("169.254.") && !h.startsWith("172.")) return h;
                    }
                }
            }
        } catch (Exception e) {
            Log.w("DlnaRenderer", "getLanIp", e);
        }
        return "127.0.0.1";
    }

    private String location() {
        return "http://" + hostIp + ":" + httpPort + "/dd.xml";
    }

    private void ssdpLoop() {
        DatagramSocket replySock = null;
        MulticastSocket sock = null;
        try {
            sock = new MulticastSocket(1900);
            sock.setReuseAddress(true);
            sock.joinGroup(InetAddress.getByName("239.255.255.250"));
            replySock = new DatagramSocket();
            sendNotify(replySock);
            byte[] buf = new byte[2048];
            while (running) {
                try {
                    DatagramPacket p = new DatagramPacket(buf, buf.length);
                    sock.receive(p);
                    String msg = new String(p.getData(), 0, p.getLength(), "UTF-8");
                    if (msg.startsWith("M-SEARCH") && (msg.contains("MediaRenderer") || msg.contains("upnp:rootdevice") || msg.contains("ssdp:all"))) {
                        byte[] r = ssdpResponse().getBytes("UTF-8");
                        DatagramPacket rp = new DatagramPacket(r, r.length, p.getAddress(), p.getPort());
                        replySock.send(rp);
                    }
                } catch (IOException e) {
                    if (!running) break;
                }
            }
        } catch (IOException e) {
            Log.e("DlnaRenderer", "SSDP 错误", e);
        } finally {
            try { if (sock != null) { sock.leaveGroup(InetAddress.getByName("239.255.255.250")); sock.close(); } } catch (Exception e) {}
            try { if (replySock != null) replySock.close(); } catch (Exception e) {}
        }
    }

    private void sendNotify(DatagramSocket s) {
        try {
            byte[] d = ssdpNotify().getBytes("UTF-8");
            DatagramPacket p = new DatagramPacket(d, d.length, InetAddress.getByName("239.255.255.250"), 1900);
            s.send(p);
        } catch (IOException e) {
            Log.w("DlnaRenderer", "notify", e);
        }
    }

    private String ssdpResponse() {
        return "HTTP/1.1 200 OK\r\n" +
            "CACHE-CONTROL: max-age=1800\r\n" +
            "EXT:\r\n" +
            "LOCATION: " + location() + "\r\n" +
            "SERVER: ADBWeb/1.0 UPnP/1.0\r\n" +
            "ST: " + ST + "\r\n" +
            "USN: " + USN + "\r\n" +
            "\r\n";
    }

    private String ssdpNotify() {
        return "NOTIFY * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "CACHE-CONTROL: max-age=1800\r\n" +
            "LOCATION: " + location() + "\r\n" +
            "NT: " + ST + "\r\n" +
            "NTS: ssdp:alive\r\n" +
            "USN: " + USN + "\r\n" +
            "\r\n";
    }

    private class HttpServer extends NanoHTTPD {
        HttpServer(int port) { super(port); }

        @Override
        public NanoHTTPD.Response serve(IHTTPSession session) {
            String uri = session.getUri();
            if ("/dd.xml".equals(uri)) return NanoHTTPD.newFixedLengthResponse(NanoHTTPD.Response.Status.OK, "text/xml", deviceXml());
            if ("/scd.xml".equals(uri)) return NanoHTTPD.newFixedLengthResponse(NanoHTTPD.Response.Status.OK, "text/xml", serviceXml());
            if ("/control".equals(uri)) {
                try {
                    return handleSoap(readBody(session));
                } catch (Exception e) {
                    Log.e("DlnaRenderer", "soap", e);
                    return NanoHTTPD.newFixedLengthResponse(NanoHTTPD.Response.Status.INTERNAL_ERROR, "text/xml", "");
                }
            }
            if ("/sub".equals(uri)) {
                NanoHTTPD.Response r = NanoHTTPD.newFixedLengthResponse(NanoHTTPD.Response.Status.OK, "text/xml", "");
                r.addHeader("SID", "uuid:" + UUID);
                r.addHeader("TIMEOUT", "Second-1800");
                return r;
            }
            return NanoHTTPD.newFixedLengthResponse(NanoHTTPD.Response.Status.NOT_FOUND, "text/plain", "");
        }
    }

    private String readBody(IHTTPSession s) throws IOException {
        InputStream is = s.getInputStream();
        ByteArrayOutputStream bos = new ByteArrayOutputStream();
        byte[] b = new byte[1024];
        int n;
        while ((n = is.read(b)) != -1) bos.write(b, 0, n);
        return bos.toString("UTF-8");
    }

    private NanoHTTPD.Response handleSoap(String xml) {
        String action = "";
        Matcher m = Pattern.compile("<(\\w+:)?(SetAVTransportURI|Play|Pause|Stop|Seek|GetTransportInfo|GetPositionInfo|GetMediaInfo|GetCurrentTransportActions|GetProtocolInfo|GetVolume|SetVolume|GetMute|SetMute)\\b").matcher(xml);
        if (m.find()) action = m.group(2);
        String resp;
        switch (action) {
            case "SetAVTransportURI": {
                String uri = arg(xml, "CurrentURI");
                String meta = arg(xml, "CurrentURIMetaData");
                String title = "";
                Matcher tm = Pattern.compile("<dc:title>([\\s\\S]*?)</dc:title>").matcher(meta);
                if (!tm.find()) tm = Pattern.compile("&lt;dc:title&gt;([\\s\\S]*?)&lt;/dc:title&gt;").matcher(meta);
                if (tm.find()) title = tm.group(1);
                if (listener != null) listener.onSetUri(uri, title);
                resp = soap("SetAVTransportURI", "<InstanceID>0</InstanceID>");
                break;
            }
            case "Play": if (listener != null) listener.onPlay(); resp = soap("Play", "<InstanceID>0</InstanceID><Speed>1</Speed>"); break;
            case "Pause": if (listener != null) listener.onPause(); resp = soap("Pause", "<InstanceID>0</InstanceID>"); break;
            case "Stop": if (listener != null) listener.onStop(); resp = soap("Stop", "<InstanceID>0</InstanceID>"); break;
            case "GetTransportInfo": resp = soap("GetTransportInfo", "<InstanceID>0</InstanceID><CurrentTransportState>STOPPED</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed>"); break;
            case "GetPositionInfo": resp = soap("GetPositionInfo", "<InstanceID>0</InstanceID><Track>0</Track><TrackDuration>00:00:00</TrackDuration><TrackMetaData></TrackMetaData><TrackURI></TrackURI><RelTime>00:00:00</RelTime><AbsTime>00:00:00</AbsTime><RelCount>0</RelCount><AbsCount>0</AbsCount>"); break;
            case "GetMediaInfo": resp = soap("GetMediaInfo", "<InstanceID>0</InstanceID><NrTracks>0</NrTracks><MediaDuration>00:00:00</MediaDuration><CurrentURI></CurrentURI><CurrentURIMetaData></CurrentURIMetaData>"); break;
            case "GetCurrentTransportActions": resp = soap("GetCurrentTransportActions", "<InstanceID>0</InstanceID><Actions>Play,Stop,Pause</Actions>"); break;
            case "GetProtocolInfo": resp = soap("GetProtocolInfo", "<Source></Source><Sink></Sink>"); break;
            default: resp = soap(action.isEmpty() ? "NoAction" : action, "<InstanceID>0</InstanceID>");
        }
        return NanoHTTPD.newFixedLengthResponse(NanoHTTPD.Response.Status.OK, "text/xml", resp);
    }

    private String arg(String xml, String name) {
        Matcher m = Pattern.compile("<" + name + ">([\\s\\S]*?)</" + name + ">").matcher(xml);
        return m.find() ? m.group(1) : "";
    }

    private String soap(String action, String body) {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" +
            "<s:Body><u:" + action + "Response xmlns:u=\"" + AV_NS + "\">" + body + "</u:" + action + "Response></s:Body></s:Envelope>";
    }

    private String deviceXml() {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n" +
            "<root xmlns=\"urn:schemas-upnp-org:device-1-0\">\r\n" +
            "<specVersion><major>1</major><minor>0</minor></specVersion>\r\n" +
            "<device>\r\n" +
            "<deviceType>" + ST + "</deviceType>\r\n" +
            "<friendlyName>" + FRIENDLY + "</friendlyName>\r\n" +
            "<manufacturer>adb-web-tool</manufacturer>\r\n" +
            "<modelName>ADB Web Cast</modelName>\r\n" +
            "<UDN>uuid:" + UUID + "</UDN>\r\n" +
            "<serviceList>\r\n" +
            "<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><serviceId>urn:upnp-org:serviceId:AVTransport</serviceId><controlURL>/control</controlURL><eventSubURL>/sub</eventSubURL></service>\n" +
            "<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId><controlURL>/control</controlURL><eventSubURL>/sub</eventSubURL></service>\n" +
            "<service><serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType><serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId><controlURL>/control</controlURL><eventSubURL>/sub</eventSubURL></service>\n" +
            "</serviceList>\r\n</device></root>";
    }

    private String serviceXml() {
        String[] actions = {"SetAVTransportURI", "GetMediaInfo", "GetTransportInfo", "GetPositionInfo", "Play", "Pause", "Stop", "Seek", "GetCurrentTransportActions"};
        StringBuilder sb = new StringBuilder();
        for (String a : actions) sb.append("<action><name>").append(a).append("</name></action>");
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n" +
            "<scpd xmlns=\"urn:schemas-upnp-org:service-1-0\"><specVersion><major>1</major><minor>0</minor></specVersion>" +
            "<actionList>" + sb + "</actionList><serviceStateTable></serviceStateTable></scpd>";
    }
}
