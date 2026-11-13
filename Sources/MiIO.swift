import CommonCrypto
import CryptoKit
import Foundation

enum MiIOError: LocalizedError {
    case badToken, badAddress, timeout, badResponse, device(String)

    var errorDescription: String? {
        switch self {
        case .badToken: "Token must be 32 hex characters"
        case .badAddress: "Enter the purifier's IP address"
        case .timeout: "Purifier not responding"
        case .badResponse: "Unexpected reply from purifier"
        case .device(let message): message
        }
    }
}

/// Xiaomi miIO local protocol over UDP 54321 (AES-128-CBC, key = md5(token)).
final class MiIO: @unchecked Sendable {
    private let address: sockaddr_in
    private let token: [UInt8]
    private let key: [UInt8]
    private let iv: [UInt8]
    private var deviceID: UInt32 = 0
    private var stamp: UInt32 = 0
    private var stampAt = Date.distantPast
    private var messageID = Int.random(in: 1...9000)
    private let lock = NSLock()

    init(host: String, token hex: String, port: UInt16 = 54321) throws {
        guard let token = [UInt8](hex: hex), token.count == 16 else { throw MiIOError.badToken }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host.trimmingCharacters(in: .whitespaces), &addr.sin_addr) == 1 else {
            throw MiIOError.badAddress
        }
        address = addr
        self.token = token
        key = md5(token)
        iv = md5(key + token)
    }

    /// The device ID learned from the last handshake (0 until then).
    var id: UInt32 {
        lock.lock()
        defer { lock.unlock() }
        return deviceID
    }

    /// Finds miIO devices by broadcasting a hello on each local IPv4 network.
    /// (macOS only delivers subnet broadcasts like 192.168.1.255, not 255.255.255.255.)
    static func discover(wait: TimeInterval = 2) -> [(ip: String, did: UInt32)] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let hello: [UInt8] = [0x21, 0x31, 0x00, 0x20] + [UInt8](repeating: 0xFF, count: 28)
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        for ptr in sequence(first: interfaces, next: { $0?.pointee.ifa_next }) {
            guard let i = ptr?.pointee, let broadcast = i.ifa_dstaddr, i.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  i.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST),
                  i.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var addr = UnsafeRawPointer(broadcast).load(as: sockaddr_in.self)
            addr.sin_port = UInt16(54321).bigEndian
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, hello, hello.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var found: [(ip: String, did: UInt32)] = []
        let end = Date().addingTimeInterval(wait)
        while Date() < end {
            var buffer = [UInt8](repeating: 0, count: 64)
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count >= 32 else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            if !found.contains(where: { $0.ip == ip }) { found.append((ip, UInt32(bytes: buffer[8..<12]))) }
        }
        return found
    }

    func call(_ method: String, _ params: Any) throws -> Any {
        lock.lock()
        defer { lock.unlock() }
        do {
            return try send(method, params)
        } catch MiIOError.timeout {
            stampAt = .distantPast  // re-handshake and retry once
            return try send(method, params)
        }
    }

    private func send(_ method: String, _ params: Any) throws -> Any {
        if Date().timeIntervalSince(stampAt) > 60 { try handshake() }
        messageID = messageID % 9999 + 1
        let id = messageID
        let json = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let body = try crypt([UInt8](json), encrypt: true)
        let elapsed = UInt32(Date().timeIntervalSince(stampAt))
        let header = [0x21, 0x31] + be(UInt16(32 + body.count)) + be(UInt32(0)) + be(deviceID) + be(stamp &+ elapsed)
        let packet = header + md5(header + token + body) + body

        let reply = try exchange(packet)
        guard reply.count > 32 else { throw MiIOError.badResponse }
        var plain = try crypt(Array(reply[32...]), encrypt: false)
        while plain.last == 0 { plain.removeLast() }
        guard let object = try? JSONSerialization.jsonObject(with: Data(plain)) as? [String: Any] else {
            throw MiIOError.badResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw MiIOError.device(error["message"] as? String ?? "Purifier error")
        }
        guard object["id"] as? Int == id else { throw MiIOError.badResponse }
        return object["result"] ?? NSNull()
    }

    private func handshake() throws {
        let hello: [UInt8] = [0x21, 0x31, 0x00, 0x20] + [UInt8](repeating: 0xFF, count: 28)
        let reply = try exchange(hello)
        guard reply.count >= 32 else { throw MiIOError.badResponse }
        deviceID = UInt32(bytes: reply[8..<12])
        stamp = UInt32(bytes: reply[12..<16])
        stampAt = Date()
    }

    private func exchange(_ packet: [UInt8]) throws -> [UInt8] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw MiIOError.timeout }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = address
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { throw MiIOError.timeout }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { throw MiIOError.timeout }
        return Array(buffer[0..<count])
    }

    private func crypt(_ input: [UInt8], encrypt: Bool) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
            input, input.count, &output, output.count, &moved)
        guard status == kCCSuccess else { throw MiIOError.badResponse }
        return Array(output[0..<moved])
    }
}

private func md5(_ bytes: [UInt8]) -> [UInt8] { Array(Insecure.MD5.hash(data: bytes)) }
private func be(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
private func be(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> (24 - 8 * $0)) & 0xFF) } }

private extension UInt32 {
    init(bytes: ArraySlice<UInt8>) { self = bytes.reduce(0) { $0 << 8 | UInt32($1) } }
}

private extension [UInt8] {
    init?(hex: String) {
        let chars: [Character] = Swift.Array(hex.trimmingCharacters(in: .whitespaces).lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self = bytes
    }
}

// MARK: - Xiaomi Smart Air Purifier 4 Compact (zhimi.airp.cpa4)
// https://home.miot-spec.com/spec/zhimi.airp.cpa4

enum Prop: String, CaseIterable {
    case power, mode, pm25, filterLife, favoriteLevel, buzzer, childLock, brightness

    var ids: (siid: Int, piid: Int) {
        switch self {
        case .power: (2, 1)
        case .mode: (2, 4)  // 0 auto, 1 sleep, 2 favorite
        case .pm25: (3, 4)
        case .filterLife: (4, 1)
        case .buzzer: (6, 1)
        case .childLock: (8, 1)
        case .favoriteLevel: (9, 11)  // 0...14
        case .brightness: (13, 2)  // 0 off, 1 dim, 2 normal
        }
    }
}

struct PurifierState: Equatable {
    var power = false
    var mode = 0
    var pm25 = 0
    var filterLife = 0
    var favoriteLevel = 0
    var buzzer = false
    var childLock = false
    var brightness = 2
}

extension PurifierState {
    /// Parses get_properties rows (local miIO or Xiaomi cloud), matched by siid/piid.
    init?(rows: [[String: Any]]) {
        var values: [Prop: Any] = [:]
        for row in rows where row["code"] as? Int == 0 {
            if let siid = row["siid"] as? Int, let piid = row["piid"] as? Int,
               let prop = Prop.allCases.first(where: { $0.ids == (siid, piid) }) { values[prop] = row["value"] }
        }
        guard values[.pm25] != nil else { return nil }
        self.init()
        power = values[.power] as? Bool ?? false
        mode = values[.mode] as? Int ?? 0
        pm25 = values[.pm25] as? Int ?? 0
        filterLife = values[.filterLife] as? Int ?? 0
        favoriteLevel = values[.favoriteLevel] as? Int ?? 0
        buzzer = values[.buzzer] as? Bool ?? false
        childLock = values[.childLock] as? Bool ?? false
        brightness = values[.brightness] as? Int ?? 2
    }
}

extension MiIO {
    func readState() throws -> PurifierState {
        let params = Prop.allCases.map { ["did": $0.rawValue, "siid": $0.ids.siid, "piid": $0.ids.piid] }
        guard let rows = try call("get_properties", params) as? [[String: Any]],
              let state = PurifierState(rows: rows) else { throw MiIOError.badResponse }
        return state
    }

    func model() throws -> String {
        guard let model = (try call("miIO.info", []) as? [String: Any])?["model"] as? String else {
            throw MiIOError.badResponse
        }
        return model
    }

    static func productName(_ model: String) -> String {
        switch model {
        case "zhimi.airp.cpa4", "xiaomi.airp.cpa4": "Air Purifier 4 Compact"
        case "zhimi.airp.rmb1": "Air Purifier 4 Lite"
        default: "Air Purifier"
        }
    }

    func set(_ prop: Prop, _ value: Any) throws {
        let params = [["did": prop.rawValue, "siid": prop.ids.siid, "piid": prop.ids.piid, "value": value]]
        let rows = try call("set_properties", params) as? [[String: Any]]
        if let code = rows?.first?["code"] as? Int, code != 0 {
            throw MiIOError.device("Purifier rejected change (code \(code))")
        }
    }
}
