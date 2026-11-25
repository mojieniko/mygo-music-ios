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
TARGET_TRIPLE="${IOS_TARGET_TRIPLE:-arm64-apple-ios16.0}"

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

# 添加 iOS 必需的平台字段到 Info.plist（与 Xcode Archive 对齐，保障 mediaremoted / SpringBoard 正常识别与拉起）
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo '18.0')"
SDK_NAME="iphoneos${SDK_VERSION}"
/usr/libexec/PlistBuddy -c "Add :MinimumOSVersion string 16.0" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :DTPlatformName string iphoneos" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :DTPlatformVersion string ${SDK_VERSION}" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :DTSDKName string ${SDK_NAME}" "${APP_BUNDLE}/Info.plist" 2>/dev/null || true
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
        --minimum-deployment-target 16.0 \
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
    existing_alt = dict(sec.get("CFBundleAlternateIcons") or {})
    if alternate_icon not in existing_alt:
        # 仅声明 CFBundleIconName 指向 Assets.car 内编译资产，不注入不存在的散装 CFBundleIconFiles
        existing_alt[alternate_icon] = {
            "CFBundleIconName": alternate_icon,
        }
    else:
        entry = dict(existing_alt[alternate_icon])
        entry.pop("CFBundleIconFiles", None)
        entry.setdefault("CFBundleIconName", alternate_icon)
        existing_alt[alternate_icon] = entry
    sec["CFBundleAlternateIcons"] = existing_alt
    data[key] = sec

with open(plist_path, "wb") as f:
    plistlib.dump(data, f)
PY_EOF

# 生成标准 Entitlements 并进行 Ad-hoc 签名（嵌入 application-identifier 以确保巨魔 TrollStore 安装后 mediaremoted/SpringBoard 可正常跳转回 App；自签工具重签时会自动替换）
ENTITLEMENTS_PLIST="${BUILD_DIR}/entitlements.plist"
cat > "${ENTITLEMENTS_PLIST}" << 'ENT_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>EGOIST0001.com.egoist.mygomusic.ios</string>
	<key>com.apple.developer.team-identifier</key>
	<string>EGOIST0001</string>
	<key>keychain-access-groups</key>
	<array>
		<string>EGOIST0001.com.egoist.mygomusic.ios</string>
	</array>
</dict>
</plist>
ENT_EOF
codesign --force --deep --sign - --entitlements "${ENTITLEMENTS_PLIST}" "${APP_BUNDLE}"

echo "==> [4/4] 压缩生成 MyGoMusic.ipa..."
rm -f "${IPA_OUT}"
(
    cd "${BUILD_DIR}"
    zip -qry "${IPA_OUT}" Payload
)

echo "✅ 打包完成: ${IPA_OUT}"
ls -lh "${IPA_OUT}"
