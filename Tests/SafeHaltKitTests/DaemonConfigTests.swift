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
}
