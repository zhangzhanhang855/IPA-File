import UIKit
import WebKit
import AVFoundation
import NetworkExtension

class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    var webView: WKWebView!
    private var vpnManager: NETunnelProviderManager?
    private var isOperating = false
    private var lastLoggedMessage = ""

    // 动态获取当前 Bundle ID，避免签名工具改名后与插件对不上
    private var tunnelBundleId: String {
        let mainId = Bundle.main.bundleIdentifier ?? "com.yourname.StockScope"
        return "\(mainId).PacketTunnel"
    }

    private var appGroupId: String {
        return "group.com.yourname.StockScope"
    }

    override func loadView() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession error: \(error)")
        }

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptEnabled = true
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        let contentController = WKUserContentController()
        contentController.add(self, name: "startProxy")
        contentController.add(self, name: "stopProxy")
        contentController.add(self, name: "getProxyStatus")
        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        if let htmlPath = Bundle.main.path(forResource: "index", ofType: "html") {
            let htmlUrl = URL(fileURLWithPath: htmlPath)
            webView.loadFileURL(htmlUrl, allowingReadAccessTo: htmlUrl.deletingLastPathComponent())
        }

        // 初始化只加载一次 Manager
        reloadManager(initial: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    // MARK: - 日志推送（带去重防刷屏）
    private func logToWeb(_ message: String, level: String = "info") {
        if message == lastLoggedMessage { return }
        lastLoggedMessage = message

        DispatchQueue.main.async { [weak self] in
            let cleanMsg = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            let js = "window.appendLog && window.appendLog('\(cleanMsg)', '\(level)');"
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "startProxy":
            if isOperating { return }
            isOperating = true
            logToWeb("收到启动指令")
            if let configString = message.body as? String {
                if saveConfigToSharedGroup(configString) {
                    startTunnel()
                } else {
                    isOperating = false
                }
            } else {
                logToWeb("配置非字符串格式", level: "error")
                isOperating = false
            }

        case "stopProxy":
            logToWeb("收到停止指令")
            stopTunnel()

        case "getProxyStatus":
            sendCurrentStatus()

        default:
            break
        }
    }

    // MARK: - 文件写入
    private func saveConfigToSharedGroup(_ config: String) -> Bool {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            logToWeb("AppGroup 目录不可用: \(appGroupId)", level: "error")
            return false
        }
        let configURL = containerURL.appendingPathComponent("config.json")
        do {
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            logToWeb("config.json 已保存")
            return true
        } catch {
            logToWeb("保存配置失败: \(error.localizedDescription)", level: "error")
            return false
        }
    }

    // MARK: - VPN 管理核心
    private func reloadManager(initial: Bool = false, completion: ((NETunnelProviderManager?) -> Void)? = nil) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.logToWeb("读取系统 VPN 描述失败: \(error.localizedDescription)", level: "error")
                completion?(nil)
                return
            }

            if let existing = managers?.first {
                self.vpnManager = existing
                if initial { self.logToWeb("已检测到系统 VPN 描述") }
                completion?(existing)
            } else {
                if initial { self.logToWeb("未注册 VPN 描述，等待点击创建") }
                let newManager = NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = self.tunnelBundleId
                proto.serverAddress = "127.0.0.1"
                newManager.protocolConfiguration = proto
                newManager.localizedDescription = "StockScope AnyTLS"
                newManager.isEnabled = true
                self.vpnManager = newManager
                completion?(newManager)
            }
        }
    }

    private func startTunnel() {
        reloadManager { [weak self] manager in
            guard let self = self, let manager = manager else {
                self?.isOperating = false
                return
            }

            manager.isEnabled = true
            self.logToWeb("正在请求系统注册/更新 VPN 描述...")

            manager.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.logToWeb("保存失败(弹窗未允许或证书无权): \(error.localizedDescription)", level: "error")
                    self.isOperating = false
                    return
                }

                // 保存成功后重新加载使其生效并开启
                manager.loadFromPreferences { [weak self] loadErr in
                    guard let self = self else { return }
                    if let loadErr = loadErr {
                        self.logToWeb("重载配置失败: \(loadErr.localizedDescription)", level: "error")
                        self.isOperating = false
                        return
                    }

                    do {
                        self.logToWeb("正在拉起底层 PacketTunnel...")
                        try manager.connection.startVPNTunnel()
                        self.logToWeb("startVPNTunnel 已调用")
                    } catch {
                        self.logToWeb("拉起隧道抛出异常: \(error.localizedDescription)", level: "error")
                    }
                    self.isOperating = false
                }
            }
        }
    }

    private func stopTunnel() {
        vpnManager?.connection.stopVPNTunnel()
        logToWeb("隧道停止命令已下发")
    }

    @objc private func vpnStatusDidChange() {
        sendCurrentStatus()
    }

    private func sendCurrentStatus() {
        let status = vpnManager?.connection.status ?? .disconnected
        let statusString: String
        switch status {
        case .connected: statusString = "connected"
        case .connecting: statusString = "connecting"
        case .disconnecting: statusString = "disconnecting"
        default: statusString = "disconnected"
        }

        DispatchQueue.main.async { [weak self] in
            let js = "window.onProxyStatusChange && window.onProxyStatusChange('\(statusString)');"
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
