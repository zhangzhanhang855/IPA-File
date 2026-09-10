import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var boxService: LibboxBoxService?
    private let appGroupId = "group.com.yourname.StockScope"

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group 共享目录"]))
            return
        }

        let configFile = containerURL.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configFile),
              let configString = String(data: configData, encoding: .utf8), !configString.isEmpty else {
            completionHandler(NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到有效的代理配置文件"]))
            return
        }

        // 1. 设置系统 TUN 接口
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.240"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }

            guard let self = self else { return }

            // 2. 初始化 Libbox 运行环境
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

            // 3. 构造并启动 sing-box 核心
            var serviceErr: NSError?
            self.boxService = LibboxNewService(configString, &serviceErr)
            if let err = serviceErr {
                completionHandler(err)
                return
            }

            do {
                try self.boxService?.start()
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        try? boxService?.close()
        boxService = nil
        completionHandler()
    }
}
