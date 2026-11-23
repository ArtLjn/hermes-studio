import Darwin
import SystemConfiguration

enum HermesProxyDNS {
    // Clash 默认的 Fake-IP 池。只有本机回环代理和对应的活动隧道同时存在时才声明。
    static var activeRange: String? {
        guard let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any],
            proxies[kSCPropNetProxiesHTTPSEnable as String] as? Bool == true,
            let host = proxies[kSCPropNetProxiesHTTPSProxy as String] as? String,
            ["127.0.0.1", "::1", "localhost"].contains(host) else { return nil }

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(first) }
        let requiredFlags = UInt32(IFF_UP | IFF_RUNNING | IFF_POINTOPOINT)
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard interface.ifa_flags & requiredFlags == requiredFlags,
                String(cString: interface.ifa_name).hasPrefix("utun"),
                let address = interface.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            if in_addr_t(bigEndian: ip) == 0xc6120001 { return "198.18.0.0/16" }
        }
        return nil
    }
}
