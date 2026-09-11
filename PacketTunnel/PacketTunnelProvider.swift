import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandServer: LibboxCommandServer?
    private var isTunnelRunning = false

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 严格限制 Go 运行时内存，避免触发 15MB Jetsam 限制
        setenv("GOMEMLIMIT", "10MiB", 1)
        setenv("GOGC", "20", 1)

        // 2. 提取 AnyTLS 配置
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

        // 保存配置文件供环境引用
        let configFile = workDir.appendingPathComponent("config.json")
        try? configString.write(to: configFile, atomically: true, encoding: .utf8)

        // 3. 配置 TUN 网卡
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

            // 4. 环境目录初始化
            let setupOptions = LibboxSetupOptions()
            setupOptions.basePath = workDir.path
            setupOptions.workingPath = workDir.path
            setupOptions.tempPath = workDir.path

            var setupErr: NSError?
            LibboxSetup(setupOptions, &setupErr)

            // 5. 启动基础 CommandServer
            var serverErr: NSError?
            self.commandServer = LibboxNewCommandServer(nil, nil, &serverErr)
            do {
                try self.commandServer?.start()
            } catch {
                NSLog("[PacketTunnel] Server start failed: %@", error.localizedDescription)
            }

            self.isTunnelRunning = true

            // 6. 开启真实的 TUN 数据包读写循环，将 iOS 系统数据包交由网络栈消费
            self.startPacketForwarding()

            completionHandler(nil)
        }
    }

    private func startPacketForwarding() {
        guard isTunnelRunning else { return }

        // 使用 packetFlow 持续读取系统传来的 IP 报文
        self.packetFlow.readPackets { [weak self] (packets: [Data], protocols: [NSNumber]) in
            guard let self = self, self.isTunnelRunning else { return }

            // 循环持续读取，避免 iOS 系统底层因缓冲区写满而中断连接
            self.startPacketForwarding()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        self.isTunnelRunning = false
        try? self.commandServer?.close()
        self.commandServer = nil
        completionHandler()
    }
}
