#if DEBUG
import Foundation
import LumenFoundation
import LumenCore
import LumenOrganization
import LumenKnowledge
import LumenApplication

/// Sample content for the screenshot run (`scripts/ios-ui-tests.sh` captures App Store–style
/// screenshots from it). Only a Debug build launched with both `-LumenUITesting` and
/// `-LumenScreenshotFixture` adds it, through the same services as user input, into the throwaway
/// in-memory store of a UI-testing launch; it can never reach real data.
enum ScreenshotFixture {
    static let argument = "-LumenScreenshotFixture"

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(argument)
    }

    static func seed(_ services: LumenServices) async throws {
        let today = services.today
        let projects = services.organization.projects
        let tasks = services.organization.tasks

        let launch = try await projects.create(name: "Product launch", summary: "Ship version 1.0", color: .indigo, targetDate: today.adding(days: 18))
        let home = try await projects.create(name: "Home", summary: "Projects around the house", color: .teal)
        let health = try await projects.create(name: "Health", color: .green)

        let drafts: [TaskDraft] = [
            TaskDraft(title: "Review the launch checklist", priority: .high, dueDate: today, projectID: launch.id, tags: ["work"]),
            TaskDraft(title: "Record the product walkthrough", priority: .medium, dueDate: today, projectID: launch.id),
            TaskDraft(title: "Reply to design feedback", dueDate: today, tags: ["work"]),
            TaskDraft(title: "30 minute run", dueDate: today, projectID: health.id),
            TaskDraft(title: "Book the dentist", priority: .urgent, dueDate: today.adding(days: -1), projectID: health.id),
            TaskDraft(title: "Prepare press kit", dueDate: today.adding(days: 2), projectID: launch.id),
            TaskDraft(title: "Fix the garden gate", dueDate: today.adding(days: 4), projectID: home.id),
            TaskDraft(title: "Plan the team offsite", dueDate: today.adding(days: 6), tags: ["work"]),
            TaskDraft(title: "Read “Deep Work”"),
        ]
        for draft in drafts {
            _ = try await tasks.create(draft)
        }
        for title in ["Draft release notes", "Update the roadmap", "Water the plants"] {
            let done = try await tasks.create(TaskDraft(title: title, dueDate: today, projectID: title == "Water the plants" ? home.id : launch.id))
            _ = try await tasks.complete(done.id)
        }

        let notes = services.knowledge.notes
        _ = try await notes.create(
            title: "Launch plan",
            body: """
            ## Goals
            - Public beta in three weeks
            - Five-minute onboarding

            ## Open questions
            - [ ] Pricing page copy
            - [x] Final icon

            Related: [[Weekly review]] #launch
            """,
            tags: ["launch"]
        )
        _ = try await notes.create(
            title: "Weekly review",
            body: """
            ## Wins
            - Shipped the calendar month view
            - Two focus sessions a day

            ## Next week
            - [ ] Press kit
            - [ ] Offsite agenda
            """,
            tags: ["review"]
        )
        _ = try await notes.create(title: "Reading list", body: "- Deep Work\n- The Design of Everyday Things\n- Four Thousand Weeks", tags: ["books"])
    }
}
#endif
