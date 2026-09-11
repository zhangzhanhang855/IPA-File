import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var server: LibboxCommandServer?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 压低 Go 运行时内存占用，防止触发 iOS 15MB Jetsam OOM 强杀
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
            completionHandler(NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少 AnyTLS 节点配置"]))
            return
        }

        // 3. 配置 TUN 网卡，注意避免回环
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // 排除内网与本地域，降低开销
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")
        ]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1280 // 调小 MTU 避免拆包重组爆内存

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }

            guard let self = self else {
                completionHandler(nil)
                return
            }

            completionHandler(nil)

            // 4. 后台低优先级平滑启动核心
            DispatchQueue.global(qos: .utility).async {
                let setupOptions = LibboxSetupOptions()
                setupOptions.basePath = workDir.path
                setupOptions.workingPath = workDir.path
                setupOptions.tempPath = workDir.path

                var setupErr: NSError?
                LibboxSetup(setupOptions, &setupErr)

                var serverErr: NSError?
                self.server = LibboxNewCommandServer(nil, nil, &serverErr)
                try? self.server?.start()
            }

            // 5. 持续消费 PacketFlow，防止 iOS 缓冲区堆满挂死
            self.startPacketLoop()
        }
    }

    private func startPacketLoop() {
        self.packetFlow.readPackets { [weak self] _, _ in
            self?.startPacketLoop()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.server?.close()
            self?.server = nil
            completionHandler()
        }
    }
}
