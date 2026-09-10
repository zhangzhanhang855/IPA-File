import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var client: LibboxCommandClient?
    private let appGroupId = "group.com.yourname.StockScope"

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 获取 App Group 共享目录
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group 共享目录"]))
            return
        }

        // 2. 读取前端传入的 config.json
        let configFile = containerURL.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configFile),
              let configString = String(data: configData, encoding: .utf8), !configString.isEmpty else {
            completionHandler(NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到代理配置文件"]))
            return
        }

        // 3. 配置 iOS TUN 网卡
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
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

            // 4. 环境初始化
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

            // 5. 启动 sing-box 独立核心服务
            var clientErr: NSError?
            self.client = LibboxNewStandaloneCommandClient(configString, &clientErr)
            if let err = clientErr {
                completionHandler(err)
                return
            }

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        try? client?.disconnect()
        client = nil
        completionHandler()
    }
}
