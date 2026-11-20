# iOS 16.0+ 客户端（ipa）

独立原生客户端（无 WebView），最低支持 **iOS 16.0**，由 GitHub Actions 构建未签名 IPA。

## 你需要什么

- macOS + Xcode 15 或更新（`xcodebuild` 打 ipa 用）
- 一个签名方式：苹果开发者证书、或直接用未签名 ipa 自签
  （Sideloadly / AltStore / TrollStore）

## 打包

```bash
cd ios
./build-ipa.sh              # ad-hoc 签名
./build-ipa.sh --unsigned   # 纯未签名 ipa，自行签
```

产物在 `ios/AdbWebCast-ios.ipa`。

## 装到设备

1. 打开 App，顶部填服务地址，例如 `http://192.168.1.10:8877`
2. 首次会弹「允许查找本地网络设备」，必须允许，否则局域网 http 打不开

## 关于「上传应用文件」在这个壳里的实现

网页里的 `<input type="file">`（安装 APK、上传文件）依赖
`WKUIDelegate` 的 `webView(_:runOpenPanelWith:initiatedByFrame:completionHandler:)`。
要点：

- 用 `UIDocumentPickerViewController(in: .import)` 打开系统「文件」App，
  选中的文件会被复制进 App 沙箱，避开 iOS 的 URL 权限问题。
- `parameters.allowsMultipleSelection` 映射到多选。
- **取消时也必须回调 `completionHandler(nil)`**，否则同一个 input 第二次点击
  不会再触发（iOS 16 上必现）。
- `accept` 里的 `application/vnd.android.package-archive` 在 iOS 没有对应的 UTI，
  会退化成 `public.data`，才能让 `.apk` 在选择器里可选。

## 设备页功能宫格

设备 Tab 里一击直达：屏幕截图/实时、电源、输入文字/剪贴板、Shell、自启管理、批量安装、运行日志、**健康监控**、**定时任务**。

## v3.4.0 新增

- **健康监控**：直连电视用 ADB shell 采集 CPU（`/proc/stat` 差分）、内存（`/proc/meminfo`）、存储（`df`）、电量/温度（`dumpsys battery`）、WiFi（`dumpsys wifi`）；每 2s 采样、曲线保留 60 点；「网络测速」用 `ping` + ADB 推拉 2MB 文件测延迟与吞吐。
- **定时任务**：本地保存「固定间隔 / Cron（分 时 日 月 周）」任务，可立即执行、暂停、删除；动作支持重启/关机/熄屏/唤醒/卸载/清数据/强停。iOS 不允许普通 App 后台常驻，任务在 App 打开期间轮询触发（页面内有说明）。

## v3.3.0 新增

- **应用中文名**：应用列表会从 APK 的 `AndroidManifest.xml` / `resources.arsc` 解析显示名，优先 `zh-CN → zh → 默认`，解析结果本地缓存；无结果时回退包名。
- **输入文字 / 剪贴板合并**：设备页只保留一个入口。输入框支持中文/英文，自动选择「Clipper 广播 → 系统剪贴板服务 → ASCII 直输」；同时可从手机剪贴板粘贴、复制到手机、并保留最近 8 条历史。
- **App Icon**：内置 1024×1024 图标资源（`Assets.xcassets/AppIcon.appiconset`），无需额外配置。

## 已知限制

- 未越狱签名有效期最长 7 天（免费账号）/ 1 年（付费账号），过期要重签。
- 定时任务依赖 App 前台轮询，退出 App 后不会在后台触发（iOS 系统限制）。
- 后台超过 30s 可能被系统挂起，大文件上传建议在前台完成。
