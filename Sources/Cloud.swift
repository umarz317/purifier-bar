import AppKit
import CryptoKit
import Foundation

/// A purifier found in the user's Mi Home account.
struct CloudDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let ip: String
    let token: String
}

enum CloudError: LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}

/// Xiaomi account QR login + device list, ported from
/// https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor
/// Only used once, to fetch the purifier's local IP and token. Control stays local (MiIO).
@MainActor
final class XiaomiCloud {
    struct QRCode {
        let image: NSImage
        let poll: URL
        let expires: Date
    }

    // Pakistan accounts live on "sg"; the rest are checked if nothing is found there.
    static let servers = ["sg", "de", "us", "in", "ru", "i2", "cn", "tw"]

    /// Models sharing the 4 Compact's property map (checked against miot-spec.org).
    static let supportedModels: Set = ["zhimi.airp.cpa4", "xiaomi.airp.cpa4", "zhimi.airp.rmb1"]

    private let session: URLSession
    private let agent: String
    private var userId = ""
    private var ssecurity = ""
    private var serviceToken = ""

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)
        let letters = String((0..<18).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
        let id = String((0..<13).map { _ in Character(UnicodeScalar(UInt8.random(in: 65...69))) })
        agent = "\(letters)-\(id) APP/com.xiaomi.mihome APPV/10.5.201"
    }

    func startLogin() async throws -> QRCode {
        var url = URLComponents(string: "https://account.xiaomi.com/longPolling/loginUrl")!
        url.queryItems = [
            .init(name: "_qrsize", value: "480"),
            .init(name: "qs", value: "%3Fsid%3Dxiaomiio%26_json%3Dtrue"),
            .init(name: "callback", value: "https://sts.api.io.mi.com/sts"),
            .init(name: "_hasLogo", value: "false"),
            .init(name: "sid", value: "xiaomiio"),
            .init(name: "serviceParam", value: ""),
            .init(name: "_locale", value: "en_GB"),
            .init(name: "_dc", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        let json = try await getJSON(URLRequest(url: url.url!))
        guard let qr = (json["qr"] as? String).flatMap(URL.init), let poll = (json["lp"] as? String).flatMap(URL.init)
        else { throw CloudError.failed("Couldn't start Mi Home sign-in") }
        let (data, _) = try await session.data(from: qr)
        guard let image = NSImage(data: data) else { throw CloudError.failed("Couldn't load the QR code") }
        let timeout = (json["timeout"] as? Double) ?? 300
        return QRCode(image: image, poll: poll, expires: Date().addingTimeInterval(timeout))
    }

    /// Long-polls until the QR code is scanned and approved in Mi Home.
    func waitForScan(_ qr: QRCode) async throws {
        var login: [String: Any]?
        while login == nil {
            try Task.checkCancellation()
            guard Date() < qr.expires else { throw CloudError.failed("QR code expired") }
            do {
                login = try await getJSON(URLRequest(url: qr.poll, timeoutInterval: 10))
            } catch let error as URLError where error.code == .timedOut {
                continue
            } catch is CloudError {
                try await Task.sleep(for: .seconds(1))
            }
        }
        guard let login, let ssecurity = login["ssecurity"] as? String,
              let location = (login["location"] as? String).flatMap(URL.init), let user = login["userId"]
        else { throw CloudError.failed("Mi Home sign-in failed") }
        userId = "\(user)"
        self.ssecurity = ssecurity
        _ = try await session.data(from: location)
        guard let token = session.configuration.httpCookieStorage?.cookies?.first(where: { $0.name == "serviceToken" })
        else { throw CloudError.failed("Mi Home sign-in failed") }
        serviceToken = token.value
    }

    /// Air purifiers in the account, from the first server region that has any.
    func purifiers() async throws -> [CloudDevice] {
        for server in Self.servers {
            var homes: [(id: String, owner: String)] = []
            let homeList = try? await call(server, "/v2/homeroom/gethome",
                #"{"fg": true, "fetch_share": true, "fetch_share_dev": true, "limit": 300, "app_ver": 7}"#)
            for home in (homeList?["result"] as? [String: Any])?["homelist"] as? [[String: Any]] ?? [] {
                if let id = home["id"] { homes.append(("\(id)", userId)) }
            }
            let shared = try? await call(server, "/v2/user/get_device_cnt", #"{"fetch_own": true, "fetch_share": true}"#)
            let share = ((shared?["result"] as? [String: Any])?["share"] as? [String: Any])?["share_family"]
            for home in share as? [[String: Any]] ?? [] {
                if let id = home["home_id"], let owner = home["home_owner"] { homes.append(("\(id)", "\(owner)")) }
            }

            var found: [CloudDevice] = []
            for home in homes {
                let list = try? await call(server, "/v2/home/home_device_list",
                    #"{"home_owner": \#(home.owner), "home_id": \#(home.id), "limit": 200, "get_split_device": true, "support_smart_home": true}"#)
                for device in (list?["result"] as? [String: Any])?["device_info"] as? [[String: Any]] ?? [] {
                    let model = device["model"] as? String ?? ""
                    guard Self.supportedModels.contains(model),
                          let token = device["token"] as? String, !token.isEmpty else { continue }
                    found.append(CloudDevice(
                        id: "\(device["did"] ?? model)", name: device["name"] as? String ?? "Air Purifier",
                        model: model, ip: device["localip"] as? String ?? "", token: token))
                }
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    // MARK: - Networking

    private func getJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudError.failed("Mi Home sign-in failed") }
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "&&&START&&&", with: "")
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CloudError.failed("Unexpected reply from Xiaomi")
        }
        return json
    }

    private func call(_ server: String, _ path: String, _ data: String) async throws -> [String: Any] {
        let nonce = Self.nonce()
        let fields = Self.encryptedParams(path: path, data: data, nonce: nonce, ssecurity: ssecurity)
        let query = fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .urlStrict)!)" }
        let host = server == "cn" ? "api.io.mi.com" : "\(server).api.io.mi.com"
        var request = URLRequest(url: URL(string: "https://\(host)/app\(path)?\(query.joined(separator: "&"))")!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("PROTOCAL-HTTP2", forHTTPHeaderField: "x-xiaomi-protocal-flag-cli")
        request.setValue("ENCRYPT-RC4", forHTTPHeaderField: "MIOT-ENCRYPT-ALGORITHM")
        request.setValue(
            "userId=\(userId); yetAnotherServiceToken=\(serviceToken); serviceToken=\(serviceToken); "
                + "locale=en_GB; timezone=GMT+02:00; is_daylight=1; dst_offset=3600000; channel=MI_APP_STORE",
            forHTTPHeaderField: "Cookie")
        let (body, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let plain = Self.decrypt(String(decoding: body, as: UTF8.self), nonce: nonce, ssecurity: ssecurity),
              let json = try JSONSerialization.jsonObject(with: plain) as? [String: Any]
        else { throw CloudError.failed("Unexpected reply from Xiaomi") }
        return json
    }

    // MARK: - Request signing (RC4 + SHA)

    static func nonce() -> String {
        var bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let minutes = UInt32(Date().timeIntervalSince1970 / 60)
        bytes += (0..<4).map { UInt8((minutes >> (24 - 8 * $0)) & 0xFF) }
        return Data(bytes).base64EncodedString()
    }

    static func signedNonce(_ nonce: String, ssecurity: String) -> String {
        let input = (Data(base64Encoded: ssecurity) ?? Data()) + (Data(base64Encoded: nonce) ?? Data())
        return Data(SHA256.hash(data: input)).base64EncodedString()
    }

    static func encryptedParams(path: String, data: String, nonce: String, ssecurity: String) -> [(String, String)] {
        let signed = signedNonce(nonce, ssecurity: ssecurity)
        func signature(_ params: [(String, String)]) -> String {
            let parts = ["POST", path] + params.map { "\($0)=\($1)" } + [signed]
            return Data(Insecure.SHA1.hash(data: Data(parts.joined(separator: "&").utf8))).base64EncodedString()
        }
        var params = [("data", data)]
        params.append(("rc4_hash__", signature(params)))
        params = params.map { ($0, rc4(signed, Data($1.utf8)).base64EncodedString()) }
        params.append(("signature", signature(params)))
        params += [("ssecurity", ssecurity), ("_nonce", nonce)]
        return params
    }

    static func decrypt(_ body: String, nonce: String, ssecurity: String) -> Data? {
        guard let data = Data(base64Encoded: body.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return rc4(signedNonce(nonce, ssecurity: ssecurity), data)
    }

    /// RC4 with the first 1024 keystream bytes dropped, as Xiaomi uses it.
    private static func rc4(_ base64Key: String, _ input: Data) -> Data {
        let key = [UInt8](Data(base64Encoded: base64Key) ?? Data())
        var s = [UInt8](0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }
        var i = 0
        j = 0
        func next() -> UInt8 {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            return s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }
        for _ in 0..<1024 { _ = next() }
        return Data(input.map { $0 ^ next() })
    }
}

private extension CharacterSet {
    static let urlStrict = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
