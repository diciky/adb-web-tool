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

## v3.3.0 新增

- **应用中文名**：应用列表会从 APK 的 `AndroidManifest.xml` / `resources.arsc` 解析显示名，优先 `zh-CN → zh → 默认`，解析结果本地缓存；无结果时回退包名。
- **输入文字 / 剪贴板合并**：设备页只保留一个入口。输入框支持中文/英文，自动选择「Clipper 广播 → 系统剪贴板服务 → ASCII 直输」；同时可从手机剪贴板粘贴、复制到手机、并保留最近 8 条历史。
- **App Icon**：内置 1024×1024 图标资源（`Assets.xcassets/AppIcon.appiconset`），无需额外配置。

## 已知限制

- 未越狱签名有效期最长 7 天（免费账号）/ 1 年（付费账号），过期要重签。
- `navigator.share` 在独立模式（从主屏幕启动）下不可用，壳里走的是 document picker。
- 后台超过 30s 可能被系统挂起，大文件上传建议在前台完成。
