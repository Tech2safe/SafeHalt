import Foundation
import Testing
@testable import SafeHaltKit

struct DaemonPlistTests {
    @Test func plistIsValidXML() throws {
        let s = DaemonPlist.launchd()
        #expect(s.contains("<?xml"))
        #expect(try PropertyListSerialization.propertyList(from: Data(s.utf8), format: nil) as? [String: Any] != nil)
    }
    @Test func labelAndProgram() {
        let s = DaemonPlist.launchd()
        #expect(s.contains("com.safehalt.daemon"))
        #expect(s.contains("/usr/local/bin/safehalt"))
        #expect(s.contains("RunAtLoad"))
        #expect(s.contains("KeepAlive"))
    }
    @Test func passesConfigArg() {
        #expect(DaemonPlist.launchd().contains("/Library/Application Support/SafeHalt/config.json"))
    }
}
