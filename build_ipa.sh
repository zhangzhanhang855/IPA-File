#!/bin/bash
# StockScope (with PacketTunnel Extension) iOS 打包脚本
# 用法:
#   1) 无签名打包(验证流程/TrollStore/巨魔直装):  UNSIGNED=1 ./build_ipa.sh
#   2) 自动签名(本机 Xcode 登录了付费开发者账号):  ./build_ipa.sh
#   3) 手动签名(CI/指定证书):
#      TEAM_ID=ABCDE12345 \
#      MAIN_PROFILE="StockScope Dev Profile" \
#      EXT_PROFILE="PacketTunnel Dev Profile" \
#      ./build_ipa.sh
set -euo pipefail

TEAM_ID="${TEAM_ID:-}"
MAIN_PROFILE="${MAIN_PROFILE:-${PROVISIONING_PROFILE_NAME:-}}"
EXT_PROFILE="${EXT_PROFILE:-}"
UNSIGNED="${UNSIGNED:-0}"

MAIN_BUNDLE_ID="com.yourdomain.StockScope"
EXT_BUNDLE_ID="com.yourdomain.StockScope.PacketTunnel"

# === 0. 检查依赖 ===
if ! command -v xcodegen >/dev/null 2>&1; then
  echo ">>> 未检测到 xcodegen,正在安装 ..."
  brew install xcodegen
fi

# === 1. 生成工程 ===
echo ">>> 生成 Xcode 工程 ..."
xcodegen generate

# === 2. 准备编译参数 ===
echo ">>> 归档 (archive) ..."
ARCHIVE_ARGS=(
  -project "StockScope.xcodeproj"
  -scheme "StockScope"
  -configuration "Release"
  -destination "generic/platform=iOS"
  -archivePath "build/StockScope.xcarchive"
)

if [ "$UNSIGNED" = "1" ]; then
  # 关键修复：多 Target 不能简单直接 NO，使用 Ad-Hoc 伪签名避免 PlugIns 链接失败
  echo ">>> [无签名/伪签名模式] CODE_SIGN_IDENTITY=\"-\" (Ad-hoc)"
  ARCHIVE_ARGS+=(
    CODE_SIGN_IDENTITY="-"
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=YES
  )
elif [ -n "$TEAM_ID" ]; then
  echo ">>> [手动签名模式] Team ID: $TEAM_ID"
  ARCHIVE_ARGS+=(
    CODE_SIGN_STYLE=Manual
    DEVELOPMENT_TEAM="$TEAM_ID"
  )
else
  echo ">>> [自动签名模式]"
  ARCHIVE_ARGS+=( -allowProvisioningUpdates )
fi

xcodebuild archive "${ARCHIVE_ARGS[@]}"

# === 3. 打包导出 ===
if [ "$UNSIGNED" = "1" ]; then
  echo ">>> 打包 IPA(无证书/适用于自签工具或巨魔) ..."
  APP_PATH="build/StockScope.xcarchive/Products/Applications/StockScope.app"
  if [ ! -d "$APP_PATH" ]; then
    echo "!!! 未找到 $APP_PATH,归档可能失败"
    exit 1
  fi
  
  # 验证 Extension 是否正确被打包进 PlugIns
  if [ -d "$APP_PATH/PlugIns" ]; then
    echo ">>> 检测到 PlugIns 目录，包含以下 Extension:"
    ls -l "$APP_PATH/PlugIns"
  else
    echo "⚠️ 警告: 未在 App 中检测到 PlugIns 目录，VPN 扩展可能未正常打入！"
  fi

  mkdir -p build/Payload
  cp -R "$APP_PATH" build/Payload/
  (
    cd build
    zip -qry StockScope-unsigned.ipa Payload/
  )
  rm -rf build/Payload
  echo ">>> 完成: build/StockScope-unsigned.ipa"
  ls -lh build/StockScope-unsigned.ipa
  exit 0
fi

# 签名导出流程
echo ">>> 生成 exportOptions.plist (支持 App + Extension 映射) ..."
mkdir -p build

if [ -n "$MAIN_PROFILE" ] && [ -n "$EXT_PROFILE" ]; then
  # 手动指定主 App 与 Extension 各自的描述文件
  cat > build/exportOptions.local.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>$MAIN_BUNDLE_ID</key>
        <string>$MAIN_PROFILE</string>
        <key>$EXT_BUNDLE_ID</key>
        <string>$EXT_PROFILE</string>
    </dict>
</dict>
</plist>
EOF
else
  # 自动匹配证书与描述文件
  cat > build/exportOptions.local.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
EOF
fi

echo ">>> 导出 IPA ..."
xcodebuild -exportArchive \
  -archivePath "build/StockScope.xcarchive" \
  -exportOptionsPlist "build/exportOptions.local.plist" \
  -exportPath "build" \
  $( [ -z "$TEAM_ID" ] && echo "-allowProvisioningUpdates" )

echo ">>> 完成: build/StockScope.ipa"
ls -lh build/StockScope.ipa
