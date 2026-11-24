import Foundation
import Testing
import LumenFoundation

@Suite("Identity")
struct IdentityTests {
    enum Sample {}

    @Test("identifiers encode as a bare UUID string")
    func identifierCoding() throws {
        let id = Identifier<Sample>()
        let data = try JSONEncoder().encode([id])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == "[\"\(id.uuidString)\"]")
        #expect(try JSONDecoder().decode([Identifier<Sample>].self, from: data) == [id])
    }

    @Test("entity references round-trip through their URI")
    func referenceURI() throws {
        let reference = EntityReference(kind: "task", id: UUID())
        #expect(EntityReference(uri: reference.uri) == reference)
        #expect(EntityReference(uri: "task") == nil)
        #expect(EntityReference(uri: ":\(UUID().uuidString)") == nil)
        #expect(EntityReference(uri: "task:not-a-uuid") == nil)
    }

    @Test("text helpers fold, collapse and truncate")
    func text() {
        #expect("Café  Déjà\n vu".foldedForMatching == "cafe  deja\n vu")
        #expect("  a \n\t b  ".collapsingWhitespace == "a b")
        #expect("   ".nonBlank == nil)
        #expect(" x ".nonBlank == "x")
        #expect("Résumé, draft-2".matchingTokens == ["resume", "draft", "2"])
        #expect("abcdef".truncated(to: 4) == "abc…")
        #expect("abc".truncated(to: 4) == "abc")
    }
}
