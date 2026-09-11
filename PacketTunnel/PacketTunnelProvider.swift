import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var server: LibboxCommandServer?
    private let appGroupId = "group.com.yourname.StockScope"

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 获取 App Group 共享目录
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group 不可达"]))
            return
        }

        // 2. 读取配置文件 config.json
        let configFile = containerURL.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configFile),
              let configString = String(data: configData, encoding: .utf8), !configString.isEmpty else {
            completionHandler(NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "读取 config.json 失败"]))
            return
        }

        // 3. 配置系统 TUN 网卡
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }

            guard let self = self else { return }

            // 4. 环境路径初始化
            let setupOptions = LibboxSetupOptions()
            setupOptions.basePath = containerURL.path
            setupOptions.workingPath = containerURL.path
            setupOptions.tempPath = containerURL.path

            var setupErr: NSError?
            LibboxSetup(setupOptions, &setupErr)
            if let err = setupErr {
                completionHandler(err)
                return
            }

            // 5. 启动核心服务 (传入包含 AnyTLS 的 configString)
            var startErr: NSError?
            // 新版 sing-box 独立核心加载服务
            self.server = LibboxNewCommandServer(nil, 0)
            
            // 写入运行时临时配置并载入
            let runConfig = containerURL.appendingPathComponent("running_config.json")
            try? configString.write(to: runConfig, atomically: true, encoding: .utf8)
            
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        self.server?.close()
        self.server = nil
        completionHandler()
    }
}
