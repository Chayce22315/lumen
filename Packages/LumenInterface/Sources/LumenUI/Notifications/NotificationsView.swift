import SwiftUI
import LumenCore
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication
import LumenNotifications

/// The notification inbox.
struct NotificationsView: View {
    let services: LumenServices
    let model: AppModel
    @State private var inbox: NotificationInboxViewModel

    init(services: LumenServices, model: AppModel) {
        self.services = services
        self.model = model
        _inbox = State(initialValue: NotificationInboxViewModel(services: services))
    }

    var body: some View {
        List {
            if inbox.authorization == .notDetermined || inbox.authorization == .denied {
                Section {
                    VStack(alignment: .leading, spacing: LumenSpace.s) {
                        Text("Notifications are off").lumenText(.headline)
                        Text(inbox.authorization == .denied ? "Allow notifications for Lumen in the Settings app to get reminders." : "Allow notifications to get reminders on time.")
                            .lumenText(.subheadline)
                            .foregroundStyle(LumenColor.textSecondary)
                        if inbox.authorization == .notDetermined {
                            Button("Allow notifications") { Task { await inbox.requestAuthorization() } }
                                .buttonStyle(.lumenSecondary)
                        }
                    }
                }
            }
            switch inbox.state {
            case .idle, .loading:
                SkeletonRows(count: 3)
            case .failed(let error):
                Text(error.message).foregroundStyle(LumenColor.danger)
            case .loaded(let items):
                if items.isEmpty {
                    Section { Text("You're all caught up.").foregroundStyle(LumenColor.textSecondary) }
                } else {
                    Section("Inbox") {
                        ForEach(items) { item in
                            Button { Task { await inbox.open(item, router: model.router) } } label: {
                                NotificationRow(item: item)
                            }
                            .swipeActions { Button(role: .destructive) { Task { await inbox.delete(item.id) } } label: { Label("Delete", systemImage: "trash") } }
                        }
                    }
                }
            }
            if !inbox.upcoming.isEmpty {
                Section("Scheduled") {
                    ForEach(inbox.upcoming) { item in
                        NotificationRow(item: item)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .lumenScreenBackground()
        .navigationTitle("Notifications")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Read all") { Task { await inbox.markAllRead() } }
                    .disabled(inbox.unreadCount == 0)
            }
        }
        .task { await inbox.start() }
    }
}

private struct NotificationRow: View {
    let item: InboxNotification

    var body: some View {
        HStack(alignment: .top, spacing: LumenSpace.m) {
            Circle()
                .fill(item.isRead ? Color.clear : LumenColor.accent)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lumenText(.body).foregroundStyle(LumenColor.textPrimary)
                if !item.body.isEmpty {
                    Text(item.body).lumenText(.subheadline).foregroundStyle(LumenColor.textSecondary)
                }
                Text(item.deliverAt, style: .relative).lumenText(.caption).foregroundStyle(LumenColor.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.isRead ? "" : "Unread. ")\(item.category.title): \(item.title)")
    }
}

/// Per-category delivery and quiet hours.
struct NotificationSettingsView: View {
    let services: LumenServices
    @State private var inbox: NotificationInboxViewModel

    init(services: LumenServices) {
        self.services = services
        _inbox = State(initialValue: NotificationInboxViewModel(services: services))
    }

    var body: some View {
        Form {
            ForEach(NotificationCategory.allCases) { category in
                Section {
                    Toggle("Show in inbox", isOn: Binding(
                        get: { inbox.preferences.preference(for: category).showsInInbox },
                        set: { value in Task { await inbox.setInbox(value, for: category) } }
                    ))
                    Toggle("Alerts", isOn: Binding(
                        get: { inbox.preferences.preference(for: category).deliversAlert },
                        set: { value in Task { await inbox.setAlerts(value, for: category) } }
                    ))
                } header: {
                    Text(category.title)
                } footer: {
                    Text(category.summary)
                }
            }
            Section {
                Toggle("Quiet hours", isOn: Binding(
                    get: { inbox.preferences.quietHours != nil },
                    set: { value in Task { await inbox.setQuietHours(value ? QuietHours(startMinute: 22 * 60, endMinute: 7 * 60) : nil) } }
                ))
                if let quiet = inbox.preferences.quietHours {
                    MinutePicker(title: "From", minutes: quiet.startMinute) { start in
                        Task { await inbox.setQuietHours(QuietHours(startMinute: start, endMinute: quiet.endMinute)) }
                    }
                    MinutePicker(title: "Until", minutes: quiet.endMinute) { end in
                        Task { await inbox.setQuietHours(QuietHours(startMinute: quiet.startMinute, endMinute: end)) }
                    }
                }
            } footer: {
                Text("Alerts wait until quiet hours end. Reminders you set for a specific time still arrive.")
            }
        }
        .navigationTitle("Notifications")
        .task { await inbox.load() }
    }
}

private struct MinutePicker: View {
    let title: String
    let minutes: Int
    let onChange: (Int) -> Void

    var body: some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                onChange((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            }
        ), displayedComponents: .hourAndMinute)
    }
}
