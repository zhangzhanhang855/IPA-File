import UIKit
import WebKit
import AVFoundation
import NetworkExtension

class ViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

    var webView: WKWebView!
    private let appGroupId = "group.com.yourname.StockScope"
    private let tunnelBundleId = "com.yourname.StockScope.PacketTunnel"

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

        NotificationCenter.default.addObserver(self, selector: #selector(vpnStatusDidChange), name: .NEVPNStatusDidChange, object: nil)
    }

    // MARK: - 日志推送到前端
    private func logToWeb(_ message: String, level: String = "info") {
        DispatchQueue.main.async { [weak self] in
            let escapedMsg = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            let js = "if (window.appendLog) { window.appendLog('\(escapedMsg)', '\(level)'); }"
            self?.webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "startProxy":
            logToWeb("收到启动请求...")
            if let configString = message.body as? String {
                if saveConfigToSharedGroup(configString) {
                    startTunnel()
                }
            } else {
                logToWeb("配置格式解析失败 (非字符串)", level: "error")
            }
        case "stopProxy":
            logToWeb("收到停止请求...")
            stopTunnel()
        case "getProxyStatus":
            notifyWebStatus()
        default:
            break
        }
    }

    // MARK: - 写入 App Group
    private func saveConfigToSharedGroup(_ config: String) -> Bool {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            logToWeb("错误: 无法获取 App Group 容器路径！请检查证书或 entitlements 的 App Group ID 是否与 '\(appGroupId)' 一致", level: "error")
            return false
        }
        let configURL = containerURL.appendingPathComponent("config.json")
        do {
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            logToWeb("配置已写入 App Group: \(configURL.lastPathComponent)")
            return true
        } catch {
            logToWeb("写入配置文件失败: \(error.localizedDescription)", level: "error")
            return false
        }
    }

    // MARK: - VPN Manager
    private func loadManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
        logToWeb("正在加载系统 VPN 描述配置...")
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            if let error = error {
                self?.logToWeb("加载 VPN 配置失败: \(error.localizedDescription)", level: "error")
                completion(nil)
                return
            }

            if let manager = managers?.first {
                self?.logToWeb("检测到现有 VPN 配置项")
                completion(manager)
            } else {
                self?.logToWeb("未找到现有配置，正在新建 NETunnelProviderManager...")
                let manager = NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = self?.tunnelBundleId
                proto.serverAddress = "127.0.0.1"
                manager.protocolConfiguration = proto
                manager.localizedDescription = "StockScope AnyTLS"
                manager.isEnabled = true
                
                manager.saveToPreferences { err in
                    if let err = err {
                        self?.logToWeb("保存新 VPN 配置到系统失败 (证书权限不足或用户拒绝): \(err.localizedDescription)", level: "error")
                        completion(nil)
                    } else {
                        self?.logToWeb("成功将 VPN 配置注册到系统！")
                        // 重新 load 一次确保状态有效
                        manager.loadFromPreferences { _ in
                            completion(manager)
                        }
                    }
                }
            }
        }
    }

    private func startTunnel() {
        loadManager { [weak self] manager in
            guard let manager = manager else {
                self?.logToWeb("VPN Manager 实例为空，终止启动", level: "error")
                return
            }
            manager.loadFromPreferences { err in
                if let err = err {
                    self?.logToWeb("刷新配置错误: \(err.localizedDescription)", level: "error")
                    return
                }
                manager.isEnabled = true
                manager.saveToPreferences { saveErr in
                    if let saveErr = saveErr {
                        self?.logToWeb("启用配置失败: \(saveErr.localizedDescription)", level: "error")
                        return
                    }
                    do {
                        self?.logToWeb("正在唤起 Network Extension 底层隧道...")
                        try manager.connection.startVPNTunnel()
                        self?.logToWeb("startVPNTunnel 调用成功，等待系统握手")
                    } catch {
                        self?.logToWeb("启动 VPN 隧道失败: \(error.localizedDescription)", level: "error")
                    }
                }
            }
        }
    }

    private func stopTunnel() {
        loadManager { [weak self] manager in
            guard let manager = manager else { return }
            manager.connection.stopVPNTunnel()
            self?.logToWeb("已发送停止隧道信号")
        }
    }

    @objc private func vpnStatusDidChange() {
        notifyWebStatus()
    }

    private func notifyWebStatus() {
        loadManager { [weak self] manager in
            let status = manager?.connection.status ?? .disconnected
            let statusString: String
            switch status {
            case .connected: statusString = "connected"
            case .connecting: statusString = "connecting"
            case .disconnecting: statusString = "disconnecting"
            default: statusString = "disconnected"
            }
            self?.logToWeb("底层 VPN 状态变更: \(statusString)")
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript("if (window.onProxyStatusChange) { window.onProxyStatusChange('\(statusString)'); }", completionHandler: nil)
            }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
