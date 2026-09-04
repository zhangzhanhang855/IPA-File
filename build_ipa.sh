#!/bin/bash
# StockScope iOS 打包脚本
# 用法(本机 macOS):
#   1) 装好 XcodeGen:    brew install xcodegen
#   2) 无签名打包(先验证流程):   UNSIGNED=1 ./build_ipa.sh
#   3) 自动签名(Xcode 已登录 Apple ID):  ./build_ipa.sh
#   4) 手动签名:  TEAM_ID=ABCDE12345 PROVISIONING_PROFILE_NAME="iOS Team Provisioning Profile: *" ./build_ipa.sh
#
# 用法(配合 GitHub Actions):
#   见 .github/workflows/build-ipa.yml
set -euo pipefail

TEAM_ID="${TEAM_ID:-}"
PROFILE_NAME="${PROVISIONING_PROFILE_NAME:-}"
UNSIGNED="${UNSIGNED:-0}"

# === 0. 检查依赖 ===
if ! command -v xcodegen >/dev/null 2>&1; then
  echo ">>> 未检测到 xcodegen,正在通过 Homebrew 安装 ..."
  brew install xcodegen
fi

echo ">>> 生成 Xcode 工程 ..."
xcodegen generate

echo ">>> 归档 (archive) ..."
ARCHIVE_ARGS=(
  -project "StockScope.xcodeproj"
  -scheme "StockScope"
  -configuration "Release"
  -destination "generic/platform=iOS"
  -archivePath "build/StockScope.xcarchive"
)

if [ "$UNSIGNED" = "1" ]; then
  # 无签名:跳过所有签名,验证构建流程
  echo ">>> [无签名模式] CODE_SIGNING_ALLOWED=NO"
  ARCHIVE_ARGS+=( CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO )
elif [ -n "$TEAM_ID" ]; then
  # 有 Team ID → 使用手动签名(便于 CI 一致性)
  ARCHIVE_ARGS+=( CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM_ID" )
  if [ -n "$PROFILE_NAME" ]; then
    ARCHIVE_ARGS+=( PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" )
  fi
else
  # 无 Team ID → 自动签名(Xcode 本地登录 Apple ID 即可)
  ARCHIVE_ARGS+=( -allowProvisioningUpdates )
fi

xcodebuild archive "${ARCHIVE_ARGS[@]}"

if [ "$UNSIGNED" = "1" ]; then
  # 无签名时无法走 xcodebuild -exportArchive,直接提取 .app 手动打包
  echo ">>> 打包 IPA(未签名) ..."
  APP_PATH="build/StockScope.xcarchive/Products/Applications/StockScope.app"
  if [ ! -d "$APP_PATH" ]; then
    echo "!!! 未找到 $APP_PATH,归档可能失败"
    exit 1
  fi
  mkdir -p build/Payload
  cp -R "$APP_PATH" build/Payload/
  cd build
  zip -qry StockScope-unsigned.ipa Payload/
  cd ..
  rm -rf build/Payload
  echo ">>> 完成:build/StockScope-unsigned.ipa"
  ls -lh build/StockScope-unsigned.ipa
  exit 0
fi

echo ">>> 生成 exportOptions.plist(填入 Team ID) ..."
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

echo ">>> 导出 IPA ..."
xcodebuild -exportArchive \
  -archivePath "build/StockScope.xcarchive" \
  -exportOptionsPlist "exportOptions.local.plist" \
  -exportPath "build" \
  $( [ -z "$TEAM_ID" ] && echo "-allowProvisioningUpdates" )

echo ">>> 完成:build/StockScope.ipa"
ls -lh build/StockScope.ipa
