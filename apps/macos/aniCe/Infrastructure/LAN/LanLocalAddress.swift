// SPDX-License-Identifier: GPL-3.0-or-later
// Selects numeric IPv4 addresses only from native local-network interfaces permitted by the LAN owner.
import Darwin
import Foundation

enum LanLocalAddress {
  static func ipv4(interfaceIndices: [Int]) -> String? {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return nil }
    defer { freeifaddrs(first) }
    var addresses = [Int: String]()
    var cursor = first
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      let entry = current.pointee
      guard entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
        let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
      let index = Int(if_nametoindex(entry.ifa_name))
      guard interfaceIndices.contains(index) else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count),
        nil, 0, NI_NUMERICHOST) == 0 else { continue }
      let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      if addresses[index] == nil { addresses[index] = ip }
    }
    return interfaceIndices.compactMap { addresses[$0] }.first
  }
}
