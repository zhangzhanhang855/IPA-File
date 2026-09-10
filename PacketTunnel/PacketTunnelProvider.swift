import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {

    // 使用 AnyObject 容纳 gomobile 实例，彻底避免具体类型名匹配失败
    private var client: AnyObject?
    private let appGroupId = "group.com.yourname.StockScope"

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 获取 App Group 共享目录
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group 共享目录"]))
            return
        }

        // 2. 配置 iOS TUN 虚拟网卡
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

            // 3. 初始化工作路径环境
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

            // 4. 实例化客户端对象
            self.client = LibboxNewStandaloneCommandClient()

            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        if let client = self.client as? NSObject {
            // 安全反射调用可能存在的清理方法
            let closeSel = Selector(("close"))
            let disconnectSel = Selector(("disconnect"))
            if client.responds(to: closeSel) {
                client.perform(closeSel)
            } else if client.responds(to: disconnectSel) {
                client.perform(disconnectSel)
            }
        }
        self.client = nil
        completionHandler()
    }
}
