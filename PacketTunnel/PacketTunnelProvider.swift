import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var server: LibboxCommandServer?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 提取配置
        var targetConfig: String?
        if let optConfig = options?["config"] as? String, !optConfig.isEmpty {
            targetConfig = optConfig
        } else if let proto = self.protocolConfiguration as? NETunnelProviderProtocol,
                  let protoConfig = proto.providerConfiguration?["config"] as? String, !protoConfig.isEmpty {
            targetConfig = protoConfig
        }

        // 确定工作目录
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

        // 将当前配置持久化到沙盒供排查
        let runFile = workDir.appendingPathComponent("running.json")
        try? configString.write(to: runFile, atomically: true, encoding: .utf8)

        // 2. 初始化 TUN 网络栈
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

            guard let self = self else {
                completionHandler(nil)
                return
            }

            // 关键：立即完成握手回调，通知 iOS 系统 VPN 接口建立成功
            completionHandler(nil)

            // 3. 异步在后台线程拉起 Libbox 引擎，避免挂起主线程导致系统超时
            DispatchQueue.global(qos: .userInitiated).async {
                let setupOptions = LibboxSetupOptions()
                setupOptions.basePath = workDir.path
                setupOptions.workingPath = workDir.path
                setupOptions.tempPath = workDir.path

                var setupErr: NSError?
                LibboxSetup(setupOptions, &setupErr)

                var serverErr: NSError?
                self.server = LibboxNewCommandServer(nil, nil, &serverErr)
                do {
                    try self.server?.start()
                } catch {
                    NSLog("[PacketTunnel] Libbox start failed: %@", error.localizedDescription)
                }
            }
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
