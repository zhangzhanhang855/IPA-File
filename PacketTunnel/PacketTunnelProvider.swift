import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var commandClient: LibboxCommandClient?
    private let appGroupId = "group.com.yourname.StockScope"

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 获取 App Group 共享目录
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group 目录"]))
            return
        }

        // 2. 读取前端写入的 config.json
        let configFile = containerURL.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configFile),
              let configString = String(data: configData, encoding: .utf8), !configString.isEmpty else {
            completionHandler(NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到有效的代理配置文件"]))
            return
        }

        // 3. 配置 iOS 虚拟网络接口 (TUN)
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4Settings = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }

            guard let self = self else { return }

            // 4. 启动 Libbox 核心服务
            do {
                var optErr: NSError?
                // 新版 Libbox 启动接口
                self.commandClient = LibboxNewCommandClient(nil, 0)
                
                // 设置并启动服务配置
                LibboxSetup(containerURL.path, containerURL.path, containerURL.path, false)
                
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // 停止核心
        try? commandClient?.disconnect()
        commandClient = nil
        completionHandler()
    }
}
