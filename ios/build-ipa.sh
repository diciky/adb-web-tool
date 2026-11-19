#!/usr/bin/env bash
# 打一个 iOS 16.0+ 能直接装的 ipa。
#
# 用法：
#   ./build-ipa.sh                          # ad-hoc 签名，需先配好证书/描述文件
#   ./build-ipa.sh --method development     # 装到自己的测试机
#   ./build-ipa.sh --unsigned               # 只出未签名 ipa，用 sideloadly/AltStore 自签
#
# 环境变量（配了就走手动签名）：
#   DEVELOPMENT_TEAM   苹果 Team ID
#   BUNDLE_ID          默认 cool.cnb.adbweb.console
set -euo pipefail

cd "$(dirname "$0")"

SCHEME="AdbWebCast"
PROJECT="AdbWebCast/AdbWebCast.xcodeproj"
METHOD="ad-hoc"
UNSIGNED=0
BUILD_DIR="build"
OUT_IPA="AdbWebCast-ios16.ipa"

while [ $# -gt 0 ]; do
  case "$1" in
    --method) METHOD="$2"; shift 2 ;;
    --unsigned) UNSIGNED=1; shift ;;
    --out) OUT_IPA="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

command -v xcodebuild >/dev/null 2>&1 || {
  echo "没有 xcodebuild：请在 macOS + Xcode 15（或更新）上运行，或在 CNB 的 mac 构建机上跑。" >&2
  exit 1
}

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
if [ "$UNSIGNED" -eq 0 ]; then
  SIGN_ARGS=()
  if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
    SIGN_ARGS+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
  fi
  if [ -n "${BUNDLE_ID:-}" ]; then
    SIGN_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=${BUNDLE_ID}")
  fi
fi

echo "== 归档（iOS 16.0 起）=="
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  -archivePath "$BUILD_DIR/${SCHEME}.xcarchive" \
  -destination 'generic/platform=iOS' \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  archive

if [ "$UNSIGNED" -eq 1 ]; then
  echo "== 组装未签名 ipa =="
  APP="$BUILD_DIR/${SCHEME}.xcarchive/Products/Applications/${SCHEME}.app"
  [ -d "$APP" ] || { echo "找不到 $APP"; exit 1; }
  mkdir -p "$BUILD_DIR/ipa/Payload"
  cp -R "$APP" "$BUILD_DIR/ipa/Payload/"
  (cd "$BUILD_DIR/ipa" && zip -qry "../../$OUT_IPA" Payload)
else
  echo "== 导出 ipa（method=${METHOD}）=="
  PLOUT="$BUILD_DIR/ExportOptions.plist"
  python3 - "$PLOUT" "$METHOD" <<'PY'
import plistlib, sys
path, method = sys.argv[1], sys.argv[2]
data = {
    "method": method,
    "signingStyle": "automatic",
    "stripSwiftSymbols": True,
    "compileBitcode": False,
    "destination": "export",
}
with open(path, "wb") as f:
    plistlib.dump(data, f)
PY
  xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/${SCHEME}.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$PLOUT" \
    ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}

  IPAS=$(find "$BUILD_DIR/export" -name '*.ipa' | head -1)
  [ -n "$IPAS" ] || { echo "导出失败：没有 .ipa 产物"; exit 1; }
  cp "$IPAS" "$OUT_IPA"
fi

echo
echo "完成：$(pwd)/$OUT_IPA"
echo "安装：Xcode › Window › Devices and Simulators 拖入，或用 Apple Configurator / Sideloadly。"
echo "极简安装方式（已信任证书的设备）：xcrun devicectl device install app --device <UDID> $OUT_IPA"
