#!/usr/bin/env node
// iOS 工程静态校验：CI 里跑不了完整 Xcode 编译前，先挡住「改坏了却没人发现」。
// 全部是纯文本/结构化检查，无第三方依赖。
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const proj = join(root, 'AdbWebCast');
let failed = 0;
const fail = (msg) => { console.error(`✗ ${msg}`); failed++; };
const ok = (msg) => console.log(`✓ ${msg}`);

function mustExist(rel) {
  const p = join(root, rel);
  if (!existsSync(p)) fail(`缺少文件：${rel}`);
  return p;
}

// ---------- 必需文件（原生架构，无 WebView） ----------
const required = [
  'AdbWebCast/AdbWebCast/AppDelegate.swift',
  'AdbWebCast/AdbWebCast/AdbKeys.swift',
  'AdbWebCast/AdbWebCast/AdbProtocol.swift',
  'AdbWebCast/AdbWebCast/LanScanner.swift',
  'AdbWebCast/AdbWebCast/DeviceListViewController.swift',
  'AdbWebCast/AdbWebCast/InstallViewController.swift',
  'AdbWebCast/AdbWebCast/Models.swift',
  'AdbWebCast/AdbWebCast/UIHelpers.swift',
  'AdbWebCast/AdbWebCast/DeviceHomeViewController.swift',
  'AdbWebCast/AdbWebCast/InfoViewController.swift',
  'AdbWebCast/AdbWebCast/AppsViewController.swift',
  'AdbWebCast/AdbWebCast/FilesViewController.swift',
  'AdbWebCast/AdbWebCast/AutostartViewController.swift',
  'AdbWebCast/AdbWebCast/BatchViewController.swift',
  'AdbWebCast/AdbWebCast/ToolsViewController.swift',
  'AdbWebCast/AdbWebCast/DeviceStore.swift',
  'AdbWebCast/AdbWebCast/RemoteViewController.swift',
  'AdbWebCast/AdbWebCast/ScreenViewController.swift',
  'AdbWebCast/AdbWebCast/Info.plist',
  'AdbWebCast/AdbWebCast/LaunchScreen.storyboard',
  'AdbWebCast/AdbWebCast.xcodeproj/project.pbxproj',
  'AdbWebCast/AdbWebCast.xcodeproj/xcshareddata/xcschemes/AdbWebCast.xcscheme',
  'build-ipa.sh',
];
for (const r of required) mustExist(r);
if (!failed) ok(`必需文件齐全（${required.length} 个）`);

if (existsSync(join(proj, 'AdbWebCast/WebConsoleViewController.swift'))) {
  fail('仍存在旧的 WebConsoleViewController.swift，应当移除（本项目已彻底脱离 WebView）');
}

// ---------- Swift 括号平衡 ----------
const swiftDir = join(proj, 'AdbWebCast');
const swiftFiles = readdirSync(swiftDir).filter((f) => f.endsWith('.swift'));
for (const file of swiftFiles) {
  const src = readFileSync(join(swiftDir, file), 'utf8');
  // 去掉字符串与注释后再数括号，减少误报
  const clean = src.replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  const counts = ['{}', '()', '[]'].map((pair) => ({
    pair,
    open: (clean.match(new RegExp(`\\${pair[0]}`, 'g')) || []).length,
    close: (clean.match(new RegExp(`\\${pair[1]}`, 'g')) || []).length,
  }));
  const bad = counts.filter((c) => c.open !== c.close);
  if (bad.length) fail(`${file} 括号不平衡：${bad.map((c) => `${c.pair} ${c.open}/${c.close}`).join('，')}`);
  else ok(`${file} 括号平衡（${src.split('\n').length} 行）`);
}

// ---------- ADB 协议关键常量（防字节序回归） ----------
const proto = readFileSync(join(swiftDir, 'AdbProtocol.swift'), 'utf8');
const protoMust = [
  ['0x4e584e43', 'CNXN 命令字'],
  ['0x48545541', 'AUTH 命令字（little-endian "AUTH"）'],
  ['0x4e45504f', 'OPEN 命令字'],
  ['0x59414b4f', 'OKAY 命令字'],
  ['0x45545257', 'WRTE 命令字'],
  ['0x45534c43', 'CLSE 命令字'],
  ['rsaSignatureDigestPKCS1v15SHA1', 'AUTH 签名必须用 Digest 变体'],
  ['command ^ 0xffffffff', '帧 magic 校验'],
  ['"SEND"', 'sync SEND'],
  ['"DATA"', 'sync DATA'],
  ['"DONE"', 'sync DONE'],
  ['"LIST"', 'sync LIST（列目录）'],
  ['"RECV"', 'sync RECV（下载）'],
  ['func pull', 'sync pull 下载能力'],
  ['func listDir', 'sync listDir 列目录能力'],
  ['func screenshot', 'screenshot 截图能力'],
  ['receiveStreamData', '跳过传输层 OKAY 的流读取'],
  ['pm install -r', 'install 命令'],
  ['func readDeviceInfo', '一次连接批量读取设备属性'],
];
// 帧层关键修复（v2.6.0）：packet store 缓存池 + OKAY 直接丢弃 + CLSE 回 CLSE + 通道精确匹配。
// 根治"过多 OKAY 帧 / OPEN 期间过多无关帧 / 设备信息全空"。
if (!proto.includes('msg.command == AdbCmd.clse')) fail('receiveStreamData 缺少 CLSE 分支');
if (!proto.includes('packetStore')) fail('缺少 packet store 帧缓存池（残留帧会被误判为无关帧）');
if (!proto.includes('func readFrame')) fail('缺少统一 readFrame（通道匹配 + 缓存池 + OKAY 丢弃）');
if (!proto.includes('func argsMatch')) fail('缺少 argsMatch 通道精确匹配');
if (!proto.includes('m.command != AdbCmd.okay')) fail('传输层 OKAY 未被直接消费（大文件 push 会误报过多 OKAY 帧）');
// 收到 CLSE 必须回 CLSE（不是 OKAY），否则通道状态错乱、残留污染后续命令。
if (!/msg\.command == AdbCmd\.clse[\s\S]{0,200}command: AdbCmd\.clse/.test(proto)) fail('收到对方 CLSE 应回 CLSE');
for (const [needle, desc] of protoMust) {
  if (!proto.includes(needle)) fail(`AdbProtocol.swift 缺少 ${desc}（未找到 ${needle}）`);
}
if (!proto.includes('return (local, reply.arg0)')) fail('remoteId 应取响应 arg0');
// 设备信息命令必须让 key 与值同一行（echo KEY=$(...)），否则解析全空。
if (!proto.includes('echo M=$(getprop')) fail('设备信息命令格式错误：值未与 key 同行会导致信息全空');
if (!failed) ok('ADB 协议常量与帧层关键点齐全');

// ---------- 内置鉴权密钥 ----------
const keys = readFileSync(join(swiftDir, 'AdbKeys.swift'), 'utf8');
if (!/ADB_PRIV_DER_B64\s*=/.test(keys)) fail('AdbKeys.swift 缺少内置私钥');
if (!/ADB_PUB_B64\s*=/.test(keys)) fail('AdbKeys.swift 缺少内置 ADB 公钥 blob');
if (!keys.includes('kSecAttrKeyTypeRSA')) fail('AdbKeys 未使用 RSA SecKey');
if (!failed) ok('内置 ADB 鉴权密钥齐全');

// ---------- 局域网自适应扫描 ----------
const lan = readFileSync(join(swiftDir, 'LanScanner.swift'), 'utf8');
for (const needle of ['getifaddrs', 'localInterfaces', 'inet_pton', 'scanLocalNetwork', '5555',
                       'AdbProbe.verify', 'singleIPs', 'utun', 'pdp_ip']) {
  if (!lan.includes(needle)) fail(`LanScanner.swift 缺少 ${needle}`);
}
if (readFileSync(join(swiftDir, 'AdbProtocol.swift'), 'utf8').includes('enum AdbProbe')) {
  ok('ADB 握手探测（过滤 VPN 伪开放端口）齐全');
} else fail('缺少 AdbProbe 握手探测');
if (!failed) ok('局域网扫描（自动/手动网段/IP 直连 + 5555 探测）齐全');

// ---------- AppDelegate 根控制器 ----------
const app = readFileSync(join(swiftDir, 'AppDelegate.swift'), 'utf8');
if (!app.includes('DeviceListViewController()')) fail('AppDelegate 根控制器不是 DeviceListViewController');
if (app.includes('WebConsoleViewController')) fail('AppDelegate 仍引用 WebView 控制器');

// ---------- plist 校验 ----------
function readKey(file, key) {
  const xml = readFileSync(file, 'utf8');
  const marker = `<key>${key}</key>`;
  const idx = xml.indexOf(marker);
  if (idx < 0) return null;
  const rest = xml.slice(idx + marker.length).trim();
  if (rest.startsWith('<dict')) return '(dict)';
  if (rest.startsWith('<array')) return '(array)';
  if (rest.startsWith('<true/>')) return true;
  if (rest.startsWith('<false/>')) return false;
  const m = rest.match(/<string>(.*?)<\/string>/s);
  return m ? m[1] : '（非标量）';
}
const infoPlist = mustExist('AdbWebCast/AdbWebCast/Info.plist');
const pbxText = readFileSync(join(proj, 'AdbWebCast.xcodeproj/project.pbxproj'), 'utf8');
const targets = [...pbxText.matchAll(/IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);/g)].map((m) => m[1]);
if (!targets.length) fail('project.pbxproj 没有设置 IPHONEOS_DEPLOYMENT_TARGET');
else if (new Set(targets).size !== 1) fail(`IPHONEOS_DEPLOYMENT_TARGET 各 target 不一致：${[...new Set(targets)].join(' / ')}`);
else ok(`IPHONEOS_DEPLOYMENT_TARGET = ${targets[0]}（各 target 一致）`);
// 保护：部署目标不允许高于 16.0，否则 iOS 16.6.1 等设备会「无法打开」。
for (const t of targets) {
  const [maj = 0, min = 0] = t.split('.').map(Number);
  if (maj > 16 || (maj === 16 && min > 0)) {
    fail(`IPHONEOS_DEPLOYMENT_TARGET = ${t} 过高；为兼容 iOS 16.6.1 必须 ≤ 16.0`);
  }
}

for (const key of ['NSAppTransportSecurity', 'NSLocalNetworkUsageDescription', 'UILaunchStoryboardName']) {
  if (readKey(infoPlist, key) === null) fail(`Info.plist 缺少 ${key}`);
}
const ats = readFileSync(infoPlist, 'utf8');
if (!ats.includes('NSAllowsLocalNetworking')) fail('Info.plist 缺少 NSAllowsLocalNetworking');
if (!failed) ok('Info.plist 关键键齐全');

// ---------- pbxproj 结构 + 新文件引用 ----------
if (!/rootObject = \w+/.test(pbxText)) fail('project.pbxproj 缺少 rootObject');
const braces = (pbxText.match(/{/g) || []).length - (pbxText.match(/}/g) || []).length;
if (braces !== 0) fail(`project.pbxproj 括号不平衡（差 ${braces}）`);
for (const f of ['AppDelegate.swift', 'AdbKeys.swift', 'AdbProtocol.swift', 'LanScanner.swift',
                 'DeviceListViewController.swift', 'InstallViewController.swift', 'Models.swift',
                 'UIHelpers.swift', 'DeviceHomeViewController.swift', 'InfoViewController.swift',
                 'AppsViewController.swift', 'FilesViewController.swift', 'AutostartViewController.swift',
                 'BatchViewController.swift', 'ToolsViewController.swift', 'DeviceStore.swift',
                 'RemoteViewController.swift', 'ScreenViewController.swift', 'Info.plist']) {
  if (!pbxText.includes(f)) fail(`project.pbxproj 没有引用 ${f}`);
}
// 设备持久化 + 遥控独立页 + 屏幕页关键点
const listSrc = readFileSync(join(swiftDir, 'DeviceListViewController.swift'), 'utf8');
if (!listSrc.includes('DeviceStore.all()')) fail('设备列表未读取本地记住的设备');
if (!listSrc.includes('DeviceStore.remember')) fail('设备列表未持久化连接的设备');
const homeSrc = readFileSync(join(swiftDir, 'DeviceHomeViewController.swift'), 'utf8');
if (!homeSrc.includes('RemoteViewController')) fail('功能主页缺少独立遥控页');
const screenSrc = readFileSync(join(swiftDir, 'ScreenViewController.swift'), 'utf8');
if (!screenSrc.includes('UIImageWriteToSavedPhotosAlbum')) fail('屏幕页缺少保存到相册');
if (!screenSrc.includes('while live')) fail('屏幕页缺少实时刷屏循环');
if (!failed) ok('project.pbxproj 结构完整且引用全部源码');

// ---------- ipa 构建脚本 ----------
const script = readFileSync(join(root, 'build-ipa.sh'), 'utf8');
for (const needle of ['xcodebuild', 'archive', 'Payload']) {
  if (!script.includes(needle)) fail(`build-ipa.sh 缺少 ${needle}`);
}
if (!failed) ok('build-ipa.sh 覆盖归档 + 未签名兜底');

if (failed) {
  console.error(`\n失败 ${failed} 项`);
  process.exit(1);
}
console.log('\niOS 工程静态校验通过。真正出 ipa 需要在 macOS 上跑 xcodebuild（本仓库 CI 已配置）。');
