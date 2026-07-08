import Foundation
import CryptoKit

public typealias RandomBytes = @Sendable (_ count: Int) -> [UInt8]

public struct PairingState: Codable, Equatable {
    public var codeHash: String
    public var tokenHash: String?
    public init(codeHash: String, tokenHash: String? = nil) {
        self.codeHash = codeHash; self.tokenHash = tokenHash
    }
}

/// 配对状态持久化（600 root）。绝不由沙盒 App 读写。
public struct PairingStore {
    public let path: String
    public init(path: String) { self.path = path }

    public func load() -> PairingState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(PairingState.self, from: data)
    }
    public func save(_ state: PairingState) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(state)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

public enum Pairing {
    public static let secureRandom: RandomBytes = { count in
        var buf = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &buf)
        return buf
    }

    public static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 常量时间字符串比较（避免计时侧信道）。长度不等直接 false。
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    /// 4+4 大写十六进制配对码，形如 7F3A-9C21（人易读易念）。
    public static func makeCode(_ random: RandomBytes) -> String {
        let b = random(4)
        let hex = b.map { String(format: "%02X", $0) }.joined()
        let mid = hex.index(hex.startIndex, offsetBy: 4)
        return "\(hex[hex.startIndex..<mid])-\(hex[mid...])"
    }

    /// 32 位小写十六进制不透明令牌（16 字节熵）。
    public static func makeToken(_ random: RandomBytes) -> String {
        random(16).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public static func initPairing(store: PairingStore, random: RandomBytes) throws -> String {
        let code = makeCode(random)
        try store.save(PairingState(codeHash: sha256Hex(code), tokenHash: nil))
        return code
    }

    /// 码正确 → 生成令牌、写 tokenHash、返回明文令牌；否则 nil（状态不变）。
    public static func redeem(store: PairingStore, submittedCode: String, random: RandomBytes) throws -> String? {
        guard var state = store.load() else { return nil }
        guard constantTimeEquals(sha256Hex(submittedCode), state.codeHash) else { return nil }
        let token = makeToken(random)
        state.tokenHash = sha256Hex(token)
        try store.save(state)
        return token
    }

    public static func verifyToken(store: PairingStore, bearer: String) -> Bool {
        guard let hash = store.load()?.tokenHash else { return false }
        return constantTimeEquals(sha256Hex(bearer), hash)
    }
}
