import NetworkExtension

func startProxy() {
    NETunnelProviderManager.loadAllFromPreferences { managers, _ in
        let manager = managers?.first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.yourdomain.StockScope.PacketTunnel"
        proto.serverAddress = "127.0.0.1"
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        
        manager.saveToPreferences { _ in
            manager.loadToPreferences { _ in
                try? manager.connection.startVPNTunnel()
            }
        }
    }
}
