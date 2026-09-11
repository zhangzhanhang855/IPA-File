import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider, LibboxPlatformInterfaceProtocol {

    private var boxService: LibboxBoxService?
    private let appGroupId = "group.com.yourname.StockScope"

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 获取 App Group 共享目录
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            completionHandler(NSError(domain: "PacketTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问 App Group 目录"]))
            return
        }

        // 2. 读取配置文件 config.json
        let configFile = containerURL.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configFile),
              let configString = String(data: configData, encoding: .utf8), !configString.isEmpty else {
            completionHandler(NSError(domain: "PacketTunnel", code: 2, userInfo: [NSLocalizedDescriptionKey: "未找到有效的 config.json"]))
            return
        }

        // 3. 配置 iOS 系统 TUN 网卡
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

            // 4. 环境目录初始化
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

            // 5. 将自身作为 PlatformInterface 传入，实例化真正的 BoxService 并启动
            var serviceErr: NSError?
            self.boxService = LibboxNewService(configString, self, &serviceErr)
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
        try? self.boxService?.close()
        self.boxService = nil
        completionHandler()
    }

    // MARK: - LibboxPlatformInterfaceProtocol 必需实现的底层网卡及路由桥接

    func openTun(_ options: LibboxTunOptionsProtocol?) throws -> Int32 {
        // 获取 iOS 系统分配给 packetFlow 的底层 socket 描述符
        guard let tunFd = self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 else {
            throw NSError(domain: "PacketTunnel", code: 3, userInfo: [NSLocalizedDescriptionKey: "无法获取 TUN 文件描述符"])
        }
        return tunFd
    }

    func writeLog(_ message: String?) {
        NSLog("[LibboxCore] %@", message ?? "")
    }

    func usePlatformAutoDetectInterfaceControl() -> Bool {
        return false
    }

    func autoDetectInterfaceControl(_ fd: Int32) throws {
        // 控制流保护，防止死循环回环
    }

    func readPacket() throws -> Data {
        return Data()
    }

    func writePacket(_ packet: Data?) throws {
    }
}
