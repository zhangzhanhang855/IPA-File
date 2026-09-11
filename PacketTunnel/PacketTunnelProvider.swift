import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var server: LibboxCommandServer?
    private var client: AnyObject?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 严格限制 Go 运行时内存，避免触发 15MB Jetsam 查杀
        setenv("GOMEMLIMIT", "10MiB", 1)
        setenv("GOGC", "20", 1)

        // 2. 提取配置
        var targetConfig: String?
        if let optConfig = options?["config"] as? String, !optConfig.isEmpty {
            targetConfig = optConfig
        } else if let proto = self.protocolConfiguration as? NETunnelProviderProtocol,
                  let protoConfig = proto.providerConfiguration?["config"] as? String, !protoConfig.isEmpty {
            targetConfig = protoConfig
        }

        let workDir = FileManager.default.temporaryDirectory

        if targetConfig == nil {
            let configFile = workDir.appendingPathComponent("config.json")
            if let data = try? Data(contentsOf: configFile),
               let str = String(data: data, encoding: .utf8), !str.isEmpty {
                targetConfig = str
            }
        }

        guard let configString = targetConfig, !configString.isEmpty else {
            completionHandler(NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "未获取到 AnyTLS 节点配置"]))
            return
        }

        // 保存运行配置供底层加载
        let runFile = workDir.appendingPathComponent("config.json")
        try? configString.write(to: runFile, atomically: true, encoding: .utf8)

        // 3. 配置系统虚拟网卡
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0")
        ]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1400

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }

            guard let self = self else {
                completionHandler(nil)
                return
            }

            // 4. 环境初始化
            let setupOptions = LibboxSetupOptions()
            setupOptions.basePath = workDir.path
            setupOptions.workingPath = workDir.path
            setupOptions.tempPath = workDir.path

            var setupErr: NSError?
            LibboxSetup(setupOptions, &setupErr)

            // 5. 启动核心服务
            var serverErr: NSError?
            self.server = LibboxNewCommandServer(nil, nil, &serverErr)
            do {
                try self.server?.start()
            } catch {
                NSLog("[PacketTunnel] Server start error: %@", error.localizedDescription)
            }

            // 启动独立命令执行端并载入配置文件
            self.client = LibboxNewStandaloneCommandClient()

            // 延迟完成握手，避免与系统通道死锁
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        if let client = self.client as? NSObject {
            let closeSel = Selector(("close"))
            if client.responds(to: closeSel) {
                client.perform(closeSel)
            }
        }
        self.client = nil

        try? self.server?.close()
        self.server = nil
        completionHandler()
    }
}
