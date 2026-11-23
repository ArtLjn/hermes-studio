import Foundation
import XCTest
@testable import StudioCore

final class RoleHandoffTests: XCTestCase {
    func testRoleCandidatesUseStableIdentityAndPreserveFileReferences() {
        let source = Role(name: "工程助手", summary: "", template: .blank)
        let target = Role(name: "QA 助手", summary: "", template: .blank)
        let duplicate = Role(name: "QA 助手", summary: "另一位测试助手", template: .blank)
        let exact = Role(name: "QA", summary: "", template: .blank)
        var archived = Role(name: "QA 草稿", summary: "", template: .blank)
        archived.archivedAt = Date()
        let roles = [source, target, duplicate, archived]
        for word in ["@", "@qa"] {
            XCTAssertEqual(RoleHandoff.candidates(for: word, in: roles, excluding: source.id).map(\.id),
                [target.id, duplicate.id])
        }
        XCTAssertEqual(RoleHandoff.candidates(for: "@qa", in: roles + [exact], excluding: source.id).first?.id,
            exact.id)
        for word in ["@file:notes", "@folder:docs"] {
            XCTAssertTrue(RoleHandoff.candidates(for: word, in: roles, excluding: source.id).isEmpty)
            XCTAssertEqual(HermesCompletion.reference(at: word.utf16.count, in: word)?.word, word)
        }
        XCTAssertNil(HermesCompletion.reference(at: 15, in: "test@assistants"))
    }
}
