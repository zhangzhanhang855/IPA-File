# StockScope iOS

> WebView 壳 App,主页面加载 https://jr-staff-center.onrender.com/admin.html
> 通过 GitHub Actions 在云端 macOS runner 上自动打包 IPA,无需本地 Mac。

---

## 目录结构

```
ios_project_StockScope/
├── .github/workflows/build-ipa.yml   # 云打包 workflow
├── StockScope/                        # 工程源码
│   ├── AppDelegate.swift
│   ├── ViewController.swift           # WKWebView 直接加载远程页面
│   ├── Info.plist
│   └── Assets.xcassets/
│       ├── Contents.json
│       └── AppIcon.appiconset/
│           ├── Contents.json
│           └── AppIcon.png            # 1024×1024 程序生成,纯 Python 无第三方依赖
├── tools/generate_icon.py             # 重新生成图标脚本
├── build_ipa.sh                       # 本机打包脚本(macOS)
├── exportOptions.plist                # 导出配置(模板)
├── project.yml                        # XcodeGen 工程描述
└── README.md
```

---

## 一、用 GitHub Actions 云打包(推荐,无需 Mac)

### 1. 把代码推到 GitHub

```bash
git init && git add -A && git commit -m "init"
git remote add origin git@github.com:<你的用户名>/ios_ipa_test.git
git push -u origin main
```

### 2. 在 GitHub 配置 Secrets

进入 `Settings → Secrets and variables → Actions → New repository secret`,依次添加:

| Secret 名称 | 内容 |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `.p12` 证书的 base64 编码 |
| `P12_PASSWORD` | 导出 .p12 时设置的密码 |
| `BUILD_PROVISION_PROFILE_BASE64` | `.mobileprovision` 描述文件的 base64 |
| `KEYCHAIN_PASSWORD` | 任意强字符串(临时 keychain 密码) |
| `TEAM_ID` | 10 位 Apple Developer Team ID |

`PROVISIONING_PROFILE_NAME`(可选):描述文件名称,留空则按 bundle id 自动匹配。

### 3. 怎么导出 .p12 和描述文件(只需执行一次)

> 这一步需要借一台 Mac(朋友的、自己去店里用、Mac mini 云租的都可以)。这是 GitHub Actions 唯一绕不过的环节,Apple 强制要求设备注册一次。

1. 在 Mac 上安装 Xcode,从 Apple ID 登录
2. USB 连接 iPhone,Xcode 打开本工程,选择真机 → 顶部菜单 **Product → Run**
   * 首次会提示 "Create Personal Team",同意即可
   * 等待 Xcode 自动生成 `Apple Development` 证书与含设备 UDID 的描述文件
3. 导出证书:**钥匙串访问** → 顶部切换到「我的证书」 → 找到 `Apple Development: 你的 Apple ID (TEAMID)` → 右键 → **导出"Apple Development: …"** → 命名 `Certificates.p12` 并设密码
   ```bash
   base64 -i Certificates.p12 | pbcopy
   ```
4. 导出描述文件:
   ```bash
   # 找到对应的描述文件(文件名即 UUID):
   ls ~/Library/MobileDevice/Provisioning\ Profiles/
   # 复制一份到桌面后:
   base64 -i ~/Library/MobileDevice/Provisioning\ Profiles/<UUID>.mobileprovision | pbcopy
   ```
   把 base64 字符串粘到 `BUILD_PROVISION_PROFILE_BASE64`
5. Team ID:登录 https://developer.apple.com/account → **Membership** → Team ID

### 4. 触发打包

- **自动**:push 到 `main` 分支即触发
- **手动**:Actions 页面 → 选择 Build iOS IPA → Run workflow

### 5. 取 IPA

Workflow 跑完后,页面底部 **Artifacts** 区下载 `StockScope-IPA`,解压得到 `StockScope.ipa`。

### 6. 安装到 iPhone

下载后两种方式:
- **Mac**:双击 .ipa 自动打开 Xcode Organizer,选择设备 Install
- **Windows(推荐免费)**:下载 [Sideloadly](https://sideloadly.io/),用同一 Apple ID 输入 app-specific password 即可装到自己的 iPhone(7 天有效)

---

## 二、本机 Mac 直接打包

```bash
brew install xcodegen
./build_ipa.sh
# 或带 Team ID 的手动签名:
TEAM_ID=ABCDE12345 ./build_ipa.sh
```

产物在 `build/StockScope.ipa`。

---

## 三、上架 App Store

需要付费 Apple Developer Program(USD 99/年):
1. 把 `exportOptions.plist` 与 workflow 里的 `<string>development</string>` 改成 `<string>app-store</string>`
2. 改完重新跑 workflow,下载 IPA 用 **Transporter** 上传到 App Store Connect

---

## 注意事项

- **加载页面**:App 通过 WKWebView 直接加载 `https://jr-staff-center.onrender.com/admin.html`(非 iframe,不受 X-Frame-Options 限制)。Info.plist 已开启 `NSAllowsArbitraryLoads` 兜底。
- **图标重新生成**:修改 `tools/generate_icon.py` 后执行 `python tools/generate_icon.py` 即可。
- **Apple ID 应用专用密码**(用 Sideloadly 装 IPA 时):在 https://appleid.apple.com → App-Specific Passwords 生成。