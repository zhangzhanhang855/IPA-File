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

        // 注册给前端调用的 JS 消息桥接
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

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "startProxy":
            if let configString = message.body as? String {
                saveConfigToSharedGroup(configString)
                startTunnel()
            }
        case "stopProxy":
            stopTunnel()
        case "getProxyStatus":
            notifyWebStatus()
        default:
            break
        }
    }

    // MARK: - App Group 配置写入
    private func saveConfigToSharedGroup(_ config: String) {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let configURL = containerURL.appendingPathComponent("config.json")
            try? config.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - VPN Manager
    private func loadManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let manager = managers?.first {
                completion(manager)
            } else {
                let manager = NETunnelProviderManager()
                let proto = NETunnelProviderProtocol()
                proto.providerBundleIdentifier = self.tunnelBundleId
                proto.serverAddress = "127.0.0.1"
                manager.protocolConfiguration = proto
                manager.localizedDescription = "StockScope AnyTLS"
                manager.isEnabled = true
                manager.saveToPreferences { err in
                    completion(err == nil ? manager : nil)
                }
            }
        }
    }

    private func startTunnel() {
        loadManager { manager in
            guard let manager = manager else { return }
            manager.loadFromPreferences { _ in
                manager.isEnabled = true
                manager.saveToPreferences { _ in
                    do {
                        try manager.connection.startVPNTunnel()
                    } catch {
                        print("Failed to start tunnel: \(error)")
                    }
                }
            }
        }
    }

    private func stopTunnel() {
        loadManager { manager in
            manager?.connection.stopVPNTunnel()
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
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript("if (window.onProxyStatusChange) { window.onProxyStatusChange('\(statusString)'); }", completionHandler: nil)
            }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
