#!/bin/bash
set -euo pipefail

TEAM_ID="${TEAM_ID:-}"
PROFILE_NAME="${PROVISIONING_PROFILE_NAME:-}"
UNSIGNED="${UNSIGNED:-0}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo ">>> 未检测到 xcodegen，正在安装..."
  brew install xcodegen
fi

echo ">>> 生成 Xcode 工程..."
xcodegen generate

echo ">>> 归档 (archive)..."
ARCHIVE_ARGS=(
  -project "StockScope.xcodeproj"
  -scheme "StockScope"
  -configuration "Release"
  -destination "generic/platform=iOS"
  -archivePath "build/StockScope.xcarchive"
)

if [ "$UNSIGNED" = "1" ]; then
  echo ">>> [无签名模式] CODE_SIGNING_ALLOWED=NO"
  ARCHIVE_ARGS+=( CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" )
elif [ -n "$TEAM_ID" ]; then
  ARCHIVE_ARGS+=( CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" )
  if [ -n "$PROFILE_NAME" ]; then
    ARCHIVE_ARGS+=( PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" )
  fi
else
  ARCHIVE_ARGS+=( -allowProvisioningUpdates )
fi

xcodebuild archive "${ARCHIVE_ARGS[@]}"

if [ "$UNSIGNED" = "1" ]; then
  echo ">>> 打包 IPA (未签名)..."
  APP_PATH="build/StockScope.xcarchive/Products/Applications/StockScope.app"
  if [ ! -d "$APP_PATH" ]; then
    echo "!!! 未找到 $APP_PATH"
    exit 1
  fi
  
  # 验证 PlugIns/PacketTunnel.appex 是否成功包含
  if [ -d "$APP_PATH/PlugIns/PacketTunnel.appex" ]; then
    echo ">>> 检测到 PlugIns/PacketTunnel.appex 存在。"
  else
    echo ">>> 警告: 未在 App 中发现 PlugIns，尝试从归档中查找补充..."
    find build/StockScope.xcarchive -name "PacketTunnel.appex" -exec cp -R {} "$APP_PATH/PlugIns/" \; 2>/dev/null || true
  fi

  mkdir -p build/Payload
  cp -R "$APP_PATH" build/Payload/
  cd build
  zip -qry StockScope-unsigned.ipa Payload/
  cd ..
  rm -rf build/Payload
  echo ">>> 完成: build/StockScope-unsigned.ipa"
  ls -lh build/StockScope-unsigned.ipa
  exit 0
fi

echo ">>> 生成 exportOptions.plist..."
mkdir -p build
cat > exportOptions.local.plist <<EOF
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
</dict>
</plist>
EOF

echo ">>> 导出 IPA..."
xcodebuild -exportArchive \
  -archivePath "build/StockScope.xcarchive" \
  -exportOptionsPlist "exportOptions.local.plist" \
  -exportPath "build" \
  $( [ -z "$TEAM_ID" ] && echo "-allowProvisioningUpdates" )

echo ">>> 完成: build/StockScope.ipa"
ls -lh build/StockScope.ipa
