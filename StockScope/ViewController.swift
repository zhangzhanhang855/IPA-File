import UIKit
import WebKit
import AVFoundation
import NetworkExtension

class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    var webView: WKWebView!
    private var vpnManager: NETunnelProviderManager?
    private var isOperating = false
    private var lastLoggedMessage = ""

    // 动态获取当前主 App 的 Bundle ID
    private var mainBundleId: String {
        return Bundle.main.bundleIdentifier ?? "com.yourname.StockScope"
    }

    private var tunnelBundleId: String {
        return "\(mainBundleId).PacketTunnel"
    }

    // 动态拼接 App Group
    private var appGroupId: String {
        return "group.\(mainBundleId)"
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

        reloadManager(initial: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vpnStatusDidChange),
            name: .NEVPNStatusDidChange,
            object: nil
        )
    }

    // MARK: - 日志推送
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
                // 无论写入文件是否成功，都通过内存传参兜底
                _ = saveConfigToSharedGroup(configString)
                startTunnel(configString: configString)
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

    // MARK: - 文件写入与兜底
    private func saveConfigToSharedGroup(_ config: String) -> Bool {
        // 1. 尝试动态 App Group
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let configURL = containerURL.appendingPathComponent("config.json")
            if (try? config.write(to: configURL, atomically: true, encoding: .utf8)) != nil {
                logToWeb("配置已写入 App Group: \(appGroupId)")
                return true
            }
        }

        // 2. 尝试备用默认 App Group
        if let defaultURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.yourname.StockScope") {
            let configURL = defaultURL.appendingPathComponent("config.json")
            if (try? config.write(to: configURL, atomically: true, encoding: .utf8)) != nil {
                logToWeb("配置已写入备用 App Group")
                return true
            }
        }

        logToWeb("提示: App Group 不可用，将通过内存通道直接传递配置", level: "warn")
        return false
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

    private func startTunnel(configString: String) {
        reloadManager { [weak self] manager in
            guard let self = self, let manager = manager else {
                self?.isOperating = false
                return
            }

            // 确保协议与 Bundle ID 匹配
            let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.tunnelBundleId
            proto.serverAddress = "127.0.0.1"
            
            // 关键：将配置直接放入 providerConfiguration 内存字典，Extension 可以直接拿到！
            proto.providerConfiguration = [
                "config": configString,
                "appGroupId": self.appGroupId
            ]
            manager.protocolConfiguration = proto
            manager.localizedDescription = "StockScope AnyTLS"
            manager.isEnabled = true

            self.logToWeb("正在请求系统注册/更新 VPN 描述 (触发系统弹窗)...")

            manager.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.logToWeb("保存失败(权限不足或被拒): \(error.localizedDescription)", level: "error")
                    self.isOperating = false
                    return
                }

                manager.loadFromPreferences { [weak self] loadErr in
                    guard let self = self else { return }
                    if let loadErr = loadErr {
                        self.logToWeb("重载配置失败: \(loadErr.localizedDescription)", level: "error")
                        self.isOperating = false
                        return
                    }

                    do {
                        self.logToWeb("正在拉起底层 PacketTunnel...")
                        // 启动时同时传入 options 字典进行双重保证
                        try manager.connection.startVPNTunnel(options: ["config": configString as NSObject])
                        self.logToWeb("startVPNTunnel 调用成功，正在建立握手")
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
