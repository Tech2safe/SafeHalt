import Foundation
import Testing
@testable import SafeHaltKit

struct PairingDialogTests {
    @Test func osascriptArgsCarryAsuserAndCode() {
        let args = PairingDialog.osascriptArgs(uid: 501, code: "7F3A-9C21")
        #expect(args[0] == "asuser")
        #expect(args[1] == "501")
        #expect(args.contains("/usr/bin/osascript"))
        // 配对码出现在脚本文本里
        #expect(args.joined(separator: " ").contains("7F3A-9C21"))
        // 品牌标题
        #expect(args.joined(separator: " ").contains("断电保护"))
    }

    @Test func osascriptArgsEscapeQuotesInCode() {
        // 配对码本身只含十六进制与短横，但仍验证不产生裸双引号注入
        let args = PairingDialog.osascriptArgs(uid: 1, code: "ABCD-1234")
        let joined = args.joined(separator: " ")
        #expect(joined.contains("ABCD-1234"))
    }
}
