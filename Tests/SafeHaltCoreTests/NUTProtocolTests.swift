import Testing
@testable import SafeHaltCore

struct NUTProtocolTests {
    @Test func parseUPSList() throws {
        let lines = ["BEGIN LIST UPS", "UPS ups \"Description unavailable\"", "END LIST UPS"]
        #expect(try NUTProtocol.parseUPSList(lines) == ["ups"])
    }

    @Test func parseUPSListMultiple() throws {
        let lines = ["BEGIN LIST UPS", "UPS ups \"a\"", "UPS ups1 \"b\"", "END LIST UPS"]
        #expect(try NUTProtocol.parseUPSList(lines) == ["ups", "ups1"])
    }

    @Test func parseVarLineSimple() throws {
        let v = try NUTProtocol.parseVarLine("VAR ups battery.charge \"100\"")
        #expect(v == NUTVariable(ups: "ups", name: "battery.charge", value: "100"))
    }

    @Test func parseVarLineValueWithSpaces() throws {
        let v = try NUTProtocol.parseVarLine("VAR ups device.mfr \"American Power Conversion \"")
        #expect(v.value == "American Power Conversion ")
    }

    @Test func parseVarList() throws {
        let lines = [
            "BEGIN LIST VAR ups",
            "VAR ups battery.charge \"100\"",
            "VAR ups ups.status \"OL\"",
            "END LIST VAR ups"
        ]
        let dict = try NUTProtocol.parseVarList(lines)
        #expect(dict["battery.charge"] == "100")
        #expect(dict["ups.status"] == "OL")
    }

    @Test func parseNumLogins() throws {
        #expect(try NUTProtocol.parseNumLogins("NUMLOGINS ups 2") == 2)
    }

    @Test func checkSimpleReplyOK() throws {
        // 不抛错即通过
        try NUTProtocol.checkSimpleReply("OK")
    }

    @Test func checkSimpleReplyErr() {
        #expect(throws: NUTError.server("ACCESS-DENIED")) {
            try NUTProtocol.checkSimpleReply("ERR ACCESS-DENIED")
        }
    }
}
