# iOS 18.4+ 客户端（ipa）

把 Web 控制台装进一个 iOS 原生壳，最低支持 **iOS 18.4**，可打成 ipa 安装。

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

## 已知限制

- 未越狱签名有效期最长 7 天（免费账号）/ 1 年（付费账号），过期要重签。
- `navigator.share` 在独立模式（从主屏幕启动）下不可用，壳里走的是 document picker。
- 后台超过 30s 可能被系统挂起，大文件上传建议在前台完成。
