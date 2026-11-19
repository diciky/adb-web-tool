#!/usr/bin/env node
// iOS 工程的静态校验：CI 里跑不了 Xcode，但至少能挡住「改坏了却没人发现」。
// 检查项都是纯文本/结构化校验，无第三方依赖。
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

// ---------- 必需文件 ----------
const required = [
  'AdbWebCast/AdbWebCast/AppDelegate.swift',
  'AdbWebCast/AdbWebCast/WebConsoleViewController.swift',
  'AdbWebCast/AdbWebCast/Info.plist',
  'AdbWebCast/AdbWebCast/LaunchScreen.storyboard',
  'AdbWebCast/AdbWebCast.xcodeproj/project.pbxproj',
  'AdbWebCast/AdbWebCast.xcodeproj/xcshareddata/xcschemes/AdbWebCast.xcscheme',
  'build-ipa.sh',
];
for (const r of required) mustExist(r);
if (!failed) ok(`必需文件齐全（${required.length} 个）`);

// ---------- Swift 括号平衡 ----------
const swiftDir = join(proj, 'AdbWebCast');
for (const file of readdirSync(swiftDir).filter((f) => f.endsWith('.swift'))) {
  const src = readFileSync(join(swiftDir, file), 'utf8');
  const counts = ['{}', '()', '[]'].map((pair) => {
    const open = (src.match(new RegExp(`\\${pair[0]}`, 'g')) || []).length;
    const close = (src.match(new RegExp(`\\${pair[1]}`, 'g')) || []).length;
    return { pair, open, close };
  });
  const bad = counts.filter((c) => c.open !== c.close);
  if (bad.length) fail(`${file} 括号不平衡：${bad.map((c) => `${c.pair} ${c.open}/${c.close}`).join('，')}`);
  else ok(`${file} 括号平衡（${src.split('\n').length} 行）`);
}

// ---------- 上传文件能力（本次核心） ----------
const vc = readFileSync(join(swiftDir, 'WebConsoleViewController.swift'), 'utf8');
const mustHave = [
  ['runOpenPanelWith', 'WKUIDelegate 的文件选择回调'],
  ['UIDocumentPickerViewController', '系统文件选择器'],
  ['completionHandler(nil)', '取消时要回调 completionHandler'],
  ['requestMediaCapturePermissionFor', '摄像头/麦克风授权'],
];
for (const [needle, desc] of mustHave) {
  if (!vc.includes(needle)) fail(`WebConsoleViewController.swift 缺少 ${desc}（未找到 ${needle}）`);
}
if (!failed) ok('iOS 上传文件的回调链完整');

// ---------- plist 校验（手写最小 XML 解析，只查关键键） ----------
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
else if (parseFloat(targets[0]) < 18.4) fail(`部署目标 ${targets[0]} 过低：Xcode 26 SDK 的文件选择 API 要求 iOS 18.4+`);
else ok(`IPHONEOS_DEPLOYMENT_TARGET = ${targets[0]}（各 target 一致，满足文件选择 API 要求）`);

for (const [key, want] of [
  ['NSAppTransportSecurity', '(dict)'],
  ['NSLocalNetworkUsageDescription', null],
  ['NSCameraUsageDescription', null],
]) {
  const v = readKey(infoPlist, key);
  if (v === null) fail(`Info.plist 缺少 ${key}`);
  else if (want !== null && v !== want) fail(`Info.plist ${key} 应为 ${want}，实际 ${v}`);
}
const ats = readFileSync(infoPlist, 'utf8');
if (!ats.includes('NSAllowsLocalNetworking')) fail('Info.plist 缺少 NSAllowsLocalNetworking（局域网 http 会被 ATS 拦）');
if (!ats.includes('LaunchScreen')) fail('Info.plist 缺少 UILaunchStoryboardName');
if (!failed) ok('Info.plist 关键键齐全');

// ---------- pbxproj 结构 ----------
const pbx = readFileSync(join(proj, 'AdbWebCast.xcodeproj/project.pbxproj'), 'utf8');
if (!/rootObject = \w+/.test(pbx)) fail('project.pbxproj 缺少 rootObject');
const braces = (pbx.match(/{/g) || []).length - (pbx.match(/}/g) || []).length;
if (braces !== 0) fail(`project.pbxproj 括号不平衡（差 ${braces}）`);
for (const f of ['AppDelegate.swift', 'WebConsoleViewController.swift', 'Info.plist']) {
  if (!pbx.includes(f)) fail(`project.pbxproj 没有引用 ${f}`);
}
if (!failed) ok('project.pbxproj 结构完整');

// ---------- ipa 构建脚本 ----------
const script = readFileSync(join(root, 'build-ipa.sh'), 'utf8');
for (const needle of ['xcodebuild', 'archive', 'exportArchive', 'Payload']) {
  if (!script.includes(needle)) fail(`build-ipa.sh 缺少 ${needle}`);
}
if (!failed) ok('build-ipa.sh 覆盖归档 + 导出 + 未签名兜底');

if (failed) {
  console.error(`\n失败 ${failed} 项`);
  process.exit(1);
}
console.log('\niOS 工程静态校验通过。真正出 ipa 需要在 macOS 上跑 ios/build-ipa.sh。');
