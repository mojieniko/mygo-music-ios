#!/usr/bin/env bash
# build-ipa.sh
# 一键编译并打包 MyGo Music iOS 版 (.ipa)
# 支持在安装了 Xcode (含 iPhoneOS.sdk) 的本机或 GitHub Actions (macos-15) 云端直接生成免签/自签 IPA 包
# 兼容爱思助手 (i4Tools)、AltStore、SideStore、Sideloadly、TrollStore 等安装工具

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_ICON_NAME="AppIcon"
ALTERNATE_ICON_NAME="AppIconAppleMusic"
DISPLAY_NAME="MyGo Music"
IPA_FILENAME="MyGoMusic.ipa"

for arg in "$@"; do
    case "$arg" in
        --apple-music-icon)
            PRIMARY_ICON_NAME="AppIconAppleMusic"
            ALTERNATE_ICON_NAME="AppIcon"
            DISPLAY_NAME="Apple Music"
            IPA_FILENAME="Apple Music.ipa"
            ;;
    esac
done

BUILD_DIR="${SCRIPT_DIR}/.build-ipa"
PAYLOAD_DIR="${BUILD_DIR}/Payload"
APP_BUNDLE="${PAYLOAD_DIR}/MyGoMusic.app"
IPA_OUT="${SCRIPT_DIR}/${IPA_FILENAME}"
TARGET_TRIPLE="${IOS_TARGET_TRIPLE:-arm64-apple-ios17.0}"

echo "==> [1/4] 检查 iOS SDK 环境..."
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    for candidate in /Applications/Xcode*.app/Contents/Developer; do
        if [ -d "${candidate}" ]; then
            export DEVELOPER_DIR="${candidate}"
            break
        fi
    done
fi

if ! SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)"; then
    echo "❌ 当前设备未检测到 iPhoneOS.sdk。"
    exit 1
fi

echo "    Found iPhoneOS SDK: ${SDK_PATH}"
rm -rf "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}"

echo "==> [2/4] 编译 MyGoMusicCore、MyGoMusicUI 与主程序 (${TARGET_TRIPLE})..."
xcrun --sdk iphoneos swiftc \
    -target "${TARGET_TRIPLE}" \
    -sdk "${SDK_PATH}" \
    -O -whole-module-optimization \
    -parse-as-library \
    -module-name MyGoMusicCore \
    -emit-module -emit-module-path "${BUILD_DIR}/MyGoMusicCore.swiftmodule" \
    -emit-library -static -o "${BUILD_DIR}/libMyGoMusicCore.a" \
    "${SCRIPT_DIR}"/Sources/MyGoMusicCore/*.swift

xcrun --sdk iphoneos swiftc \
    -target "${TARGET_TRIPLE}" \
    -sdk "${SDK_PATH}" \
    -O -whole-module-optimization \
    -parse-as-library \
    -I "${BUILD_DIR}" \
    -module-name MyGoMusicUI \
    -emit-module -emit-module-path "${BUILD_DIR}/MyGoMusicUI.swiftmodule" \
    -emit-library -static -o "${BUILD_DIR}/libMyGoMusicUI.a" \
    "${SCRIPT_DIR}"/Sources/MyGoMusicUI/*.swift

xcrun --sdk iphoneos swiftc \
    -target "${TARGET_TRIPLE}" \
    -sdk "${SDK_PATH}" \
    -O -parse-as-library \
    -I "${BUILD_DIR}" \
    -L "${BUILD_DIR}" \
    -lMyGoMusicUI -lMyGoMusicCore \
    -o "${APP_BUNDLE}/MyGoMusic" \
    "${SCRIPT_DIR}/App/MyGoMusicApp.swift"

echo "==> [3/4] 组装 MyGoMusic.app 资源与 Info.plist..."
sed \
    -e 's/\$(EXECUTABLE_NAME)/MyGoMusic/g' \
    -e 's/\$(PRODUCT_BUNDLE_IDENTIFIER)/com.egoist.mygomusic.ios/g' \
    -e 's/\$(PRODUCT_NAME)/MyGo Music/g' \
    "${SCRIPT_DIR}/App/Info.plist" > "${APP_BUNDLE}/Info.plist"

# 添加 iOS 必需的平台字段到 Info.plist
/usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string 17.0" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily array" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily:0 integer 1" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIDeviceFamily:1 integer 2" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms array" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleSupportedPlatforms:0 string iPhoneOS" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true

printf "APPL????" > "${APP_BUNDLE}/PkgInfo"

# 编译 AppIcon 与备用桌面图标资源目录（Assets.xcassets -> Assets.car + 主图标 PNG）
if [ -d "${SCRIPT_DIR}/App/Assets.xcassets" ]; then
    xcrun actool "${SCRIPT_DIR}/App/Assets.xcassets" \
        --compile "${APP_BUNDLE}" \
        --platform iphoneos \
        --minimum-deployment-target 17.0 \
        --app-icon "${PRIMARY_ICON_NAME}" \
        --alternate-app-icon "${ALTERNATE_ICON_NAME}" \
        --output-partial-info-plist "${BUILD_DIR}/assetcatalog_generated_info.plist" >/dev/null 2>&1 || true
fi

python3 - "${APP_BUNDLE}/Info.plist" "${BUILD_DIR}/assetcatalog_generated_info.plist" "${PRIMARY_ICON_NAME}" "${ALTERNATE_ICON_NAME}" "${DISPLAY_NAME}" << 'PY_EOF'
import os, plistlib, sys

plist_path = sys.argv[1]
partial_path = sys.argv[2]
primary_icon = sys.argv[3]
alternate_icon = sys.argv[4]
display_name = sys.argv[5]

with open(plist_path, "rb") as f:
    data = plistlib.load(f)

data["CFBundleDisplayName"] = display_name
data["CFBundleName"] = display_name
data["CFBundleIconName"] = primary_icon

if os.path.exists(partial_path):
    with open(partial_path, "rb") as pf:
        partial = plistlib.load(pf)
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        if key in partial:
            data[key] = partial[key]

alt = {
    alternate_icon: {
        "CFBundleIconName": alternate_icon
    }
}

for key, default_files in (
    ("CFBundleIcons", [f"{primary_icon}60x60"]),
    ("CFBundleIcons~ipad", [f"{primary_icon}60x60", f"{primary_icon}76x76"]),
):
    sec = dict(data.get(key) or {})
    if "CFBundlePrimaryIcon" not in sec:
        sec["CFBundlePrimaryIcon"] = {
            "CFBundleIconFiles": default_files,
            "CFBundleIconName": primary_icon,
        }
    sec["CFBundleAlternateIcons"] = alt
    data[key] = sec

with open(plist_path, "wb") as f:
    plistlib.dump(data, f)
PY_EOF

# 进行 Ad-hoc 签名（便于爱思助手/AltStore/Sideloadly 重签或 TrollStore 直接安装）
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> [4/4] 压缩生成 MyGoMusic.ipa..."
rm -f "${IPA_OUT}"
(
    cd "${BUILD_DIR}"
    zip -qry "${IPA_OUT}" Payload
)

echo "✅ 打包完成: ${IPA_OUT}"
ls -lh "${IPA_OUT}"
