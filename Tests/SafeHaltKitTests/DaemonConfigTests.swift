// Tests/SafeHaltKitTests/DaemonConfigTests.swift
import Foundation
import Testing
@testable import SafeHaltKit
@testable import SafeHaltCore

struct DaemonConfigTests {
    private let sampleJSON = """
    {"host":"192.168.1.100","port":3493,"ups":"ups","username":"monuser",
     "password":"changeme","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true,
     "commLossFailsafeMinutes":5,"pollSeconds":5}
    """

    @Test func decodesFromJSON() throws {
        let cfg = try DaemonConfig.load(data: Data(sampleJSON.utf8))
        #expect(cfg.host == "192.168.1.100")
        #expect(cfg.port == 3493)
        #expect(cfg.ups == "ups")
        #expect(cfg.onBatteryMinutes == 10)
        #expect(cfg.shutdownAlsoOnLowBattery)
        #expect(cfg.commLossFailsafeMinutes == 5)
        #expect(cfg.pollSeconds == 5)
    }

    @Test func exposesShutdownPolicy() throws {
        let cfg = try DaemonConfig.load(data: Data(sampleJSON.utf8))
        #expect(cfg.policy == ShutdownPolicy(onBatteryMinutes: 10, shutdownAlsoOnLowBattery: true))
    }

    @Test func roundtripEncode() throws {
        let cfg = try DaemonConfig.load(data: Data(sampleJSON.utf8))
        let again = try DaemonConfig.load(data: cfg.encoded())
        #expect(again == cfg)
    }

    @Test func paths() {
        #expect(DaemonPaths.label == "com.safehalt.daemon")
        #expect(DaemonPaths.binary == "/usr/local/bin/safehalt")
        #expect(DaemonPaths.cancelFlagFile == "/tmp/safehalt-cancel-shutdown")
    }

    @Test func rejectsZeroOnBatteryMinutes() {
        let bad = #"{"host":"h","port":3493,"ups":"ups","username":"u","password":"p","onBatteryMinutes":0,"shutdownAlsoOnLowBattery":true,"commLossFailsafeMinutes":5,"pollSeconds":5}"#
        #expect(throws: DaemonConfigError.self) { try DaemonConfig.load(data: Data(bad.utf8)) }
    }
    @Test func rejectsNegativeFailsafe() {
        let bad = #"{"host":"h","port":3493,"ups":"ups","username":"u","password":"p","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true,"commLossFailsafeMinutes":-1,"pollSeconds":5}"#
        #expect(throws: DaemonConfigError.self) { try DaemonConfig.load(data: Data(bad.utf8)) }
    }

    @Test func enabledDefaultsTrueWhenMissing() throws {
        // 现役机器的旧 config 无 enabled 字段，须默认启用（升级不失保护）
        let legacy = #"{"host":"h","port":3493,"ups":"ups","username":"u","password":"p","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true,"commLossFailsafeMinutes":5,"pollSeconds":5}"#
        let cfg = try DaemonConfig.load(data: Data(legacy.utf8))
        #expect(cfg.enabled == true)
    }

    @Test func credentialsOptionalDefaultEmpty() throws {
        // 匿名读 UPS 状态，无需凭据；App 的 /config 不下发 username/password
        let minimal = #"{"host":"h","port":3493,"ups":"ups","onBatteryMinutes":10,"shutdownAlsoOnLowBattery":true,"enabled":false}"#
        let cfg = try DaemonConfig.load(data: Data(minimal.utf8))
        #expect(cfg.username == "")
        #expect(cfg.password == "")
        #expect(cfg.commLossFailsafeMinutes == 0)
        #expect(cfg.pollSeconds == 5)
        #expect(cfg.enabled == false)
    }

    @Test func newPathsExist() {
        #expect(DaemonPaths.httpPort == 57117)
        #expect(DaemonPaths.pairingFile == "/Library/Application Support/SafeHalt/pairing.json")
    }
}
