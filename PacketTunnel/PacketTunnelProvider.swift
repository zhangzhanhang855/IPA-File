import NetworkExtension
import Libbox

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var service: LibboxBoxService?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 1. 配置虛擬網卡 IP（三層截流）
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["172.19.0.1"], subnetMasks: ["255.255.255.0"])
        settings.ipv4Settings?.includedRoutes = [NEIPv4Route.default()] // 攔截全部流量

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                completionHandler(error)
                return
            }

            // 2. 啟動 Libbox 核心（傳入 SS 節點 json 配置與 packetFlow 文件描述符）
            // 具體節點配置可寫死一個測試用的 SS 配置 JSON 字串
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // 停止內核
        completionHandler()
    }
}
