import Foundation
import Testing
import LumenWidgetData

@Suite("Shared container")
struct SharedContainerTests {
    @Test("the App Group comes from Info.plist, with the default when unset or unexpanded")
    func appGroupFromInfoPlist() {
        let key = SharedContainer.appGroupInfoKey
        #expect(SharedContainer.appGroupIdentifier(in: [key: "group.com.example.lumen"]) == "group.com.example.lumen")
        #expect(SharedContainer.appGroupIdentifier(in: [key: "  group.com.example.lumen\n"]) == "group.com.example.lumen")
        #expect(SharedContainer.appGroupIdentifier(in: [:]) == SharedContainer.defaultAppGroupIdentifier)
        #expect(SharedContainer.appGroupIdentifier(in: [key: ""]) == SharedContainer.defaultAppGroupIdentifier)
        #expect(SharedContainer.appGroupIdentifier(in: [key: "$(LUMEN_APP_GROUP)"]) == SharedContainer.defaultAppGroupIdentifier)
        #expect(SharedContainer.appGroupIdentifier(in: [key: 42]) == SharedContainer.defaultAppGroupIdentifier)
    }
}
