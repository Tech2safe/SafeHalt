import Foundation
import Testing
@testable import SafeHaltKit

struct PairingTests {
    // 确定性随机：返回递增字节，便于断言格式
    private let seq: RandomBytes = { count in (0..<count).map { UInt8($0 & 0xFF) } }

    @Test func codeFormatIsFourDashFourUppercaseHex() {
        let code = Pairing.makeCode(seq)   // 字节 00 01 02 03 → "0001-0203"
        #expect(code == "0001-0203")
    }

    @Test func tokenIs32LowercaseHex() {
        let token = Pairing.makeToken(seq)
        #expect(token.count == 32)
        #expect(token == token.lowercased())
        #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func sha256HexIsStable() {
        #expect(Pairing.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func constantTimeEqualsMatchesOnlyIdentical() {
        #expect(Pairing.constantTimeEquals("deadbeef", "deadbeef"))
        #expect(!Pairing.constantTimeEquals("deadbeef", "deadbee0"))
        #expect(!Pairing.constantTimeEquals("deadbeef", "deadbe"))
    }

    @Test func initPairingStoresCodeHashNoToken() throws {
        let path = NSTemporaryDirectory() + "pair-\(UInt64(abs(seq(8).hashValue))).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(path: path)
        let code = try Pairing.initPairing(store: store, random: seq)
        let state = store.load()
        #expect(state?.codeHash == Pairing.sha256Hex(code))
        #expect(state?.tokenHash == nil)
    }

    @Test func redeemWithCorrectCodeIssuesToken() throws {
        let path = NSTemporaryDirectory() + "pair-redeem-ok.json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(path: path)
        let code = try Pairing.initPairing(store: store, random: seq)
        let token = try Pairing.redeem(store: store, submittedCode: code, random: seq)
        #expect(token != nil)
        #expect(store.load()?.tokenHash == Pairing.sha256Hex(token!))
        #expect(Pairing.verifyToken(store: store, bearer: token!))
    }

    @Test func redeemWithWrongCodeReturnsNilAndNoToken() throws {
        let path = NSTemporaryDirectory() + "pair-redeem-bad.json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(path: path)
        _ = try Pairing.initPairing(store: store, random: seq)
        let token = try Pairing.redeem(store: store, submittedCode: "WRON-GCOD", random: seq)
        #expect(token == nil)
        #expect(store.load()?.tokenHash == nil)
    }

    @Test func verifyTokenFalseWhenUnpaired() throws {
        let path = NSTemporaryDirectory() + "pair-unpaired.json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PairingStore(path: path)
        _ = try Pairing.initPairing(store: store, random: seq)
        #expect(!Pairing.verifyToken(store: store, bearer: "anything"))
    }
}
