import Testing
@testable import SafeHaltCore

struct NUTFramingTests {
    @Test func isListCommand() {
        #expect(NUTFraming.isListCommand("LIST UPS"))
        #expect(NUTFraming.isListCommand("LIST VAR ups"))
        #expect(!NUTFraming.isListCommand("GET NUMLOGINS ups"))
    }

    @Test func incompleteBufferReturnsNil() throws {
        #expect(try NUTFraming.extractReply(from: "BEGIN LIST UPS\nUPS ups \"x\"", isList: true) == nil)
        #expect(try NUTFraming.extractReply(from: "OK", isList: false) == nil) // 无换行，行未完整
    }

    @Test func singleLineReplyWithRemainder() throws {
        let r = try #require(try NUTFraming.extractReply(from: "OK\nNEXT", isList: false))
        #expect(r.lines == ["OK"])
        #expect(r.remainder == "NEXT")
    }

    @Test func listReplyStopsAtEndList() throws {
        let buf = "BEGIN LIST UPS\nUPS ups \"x\"\nEND LIST UPS\nleftover"
        let r = try #require(try NUTFraming.extractReply(from: buf, isList: true))
        #expect(r.lines == ["BEGIN LIST UPS", "UPS ups \"x\"", "END LIST UPS"])
        #expect(r.remainder == "leftover")
    }

    @Test func listErrTerminates() throws {
        let r = try #require(try NUTFraming.extractReply(from: "ERR ACCESS-DENIED\n", isList: true))
        #expect(r.lines == ["ERR ACCESS-DENIED"])
        #expect(r.remainder == "")
    }

    @Test func stripsCarriageReturnsAndSkipsEmptyLines() throws {
        let r = try #require(try NUTFraming.extractReply(from: "\r\nOK\r\nrest", isList: false))
        #expect(r.lines == ["OK"])
        #expect(r.remainder == "rest")
    }
}
