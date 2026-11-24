import SwiftUI
import LumenFoundation
import LumenDesignSystem
import LumenPresentation
import LumenApplication

/// What a detail column says while nothing is selected in its list.
struct DetailPlaceholder {
    let title: String
    let message: String
    let symbolName: String

    static let task = DetailPlaceholder(title: "No Task Selected", message: "Choose a task to see and edit its details.", symbolName: "checklist")
    static let project = DetailPlaceholder(title: "No Project Selected", message: "Choose a project to see its tasks and progress.", symbolName: "square.stack.3d.up")
    static let note = DetailPlaceholder(title: "No Note Selected", message: "Choose a note or a document from the list.", symbolName: "note.text")
    static let conversation = DetailPlaceholder(title: "No Conversation Selected", message: "Choose a conversation, or start a new one.", symbolName: "bubble.left.and.text.bubble.right")
    static let automation = DetailPlaceholder(title: "No Automation Selected", message: "Choose an automation or one of its runs.", symbolName: "point.3.connected.trianglepath.dotted")
}

/// A sidebar section with its list and the selected item side by side (iPad at regular width).
///
/// The router keeps both in the section's path: the list's selection first, then the screens
/// pushed on the detail column, so the same place shows as a stack in the tab bar.
struct SplitSectionView<Primary: View>: View {
    let section: NavigationSection
    let services: LumenServices
    let model: AppModel
    let zoom: Namespace.ID
    let placeholder: DetailPlaceholder
    private let primary: (Binding<AppDestination?>) -> Primary
    @State private var columns: NavigationSplitViewVisibility = .all

    init(
        section: NavigationSection,
        services: LumenServices,
        model: AppModel,
        zoom: Namespace.ID,
        placeholder: DetailPlaceholder,
        @ViewBuilder primary: @escaping (Binding<AppDestination?>) -> Primary
    ) {
        self.section = section
        self.services = services
        self.model = model
        self.zoom = zoom
        self.placeholder = placeholder
        self.primary = primary
    }

    var body: some View {
        let router = model.router
        let section = self.section
        let selection = Binding<AppDestination?>(
            get: { router.listSelection(in: section) },
            set: { router.setListSelection($0, in: section) }
        )
        let detailPath = Binding<[AppDestination]>(
            get: { router.detailPath(in: section) },
            set: { router.setDetailPath($0, in: section) }
        )
        NavigationSplitView(columnVisibility: $columns) {
            primary(selection)
                // The same grouped rows as on iPhone, beside the detail.
                .listStyle(.insetGrouped)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
        } detail: {
            NavigationStack(path: detailPath) {
                detailRoot(router.listSelection(in: section))
                    .destinations(services: services, model: model, zoom: zoom)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func detailRoot(_ selected: AppDestination?) -> some View {
        if let selected {
            DestinationView(destination: selected, services: services, model: model)
                // Another selection is another screen, with its own view model.
                .id(selected)
        } else {
            ContentUnavailableView(placeholder.title, systemImage: placeholder.symbolName, description: Text(placeholder.message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .lumenScreenBackground()
        }
    }
}

/// A `List` whose navigation links drive a list/detail selection when it has one (iPad), and push
/// onto the enclosing stack when it doesn't (iPhone).
struct SelectableList<Content: View>: View {
    let selection: Binding<AppDestination?>?
    private let content: Content

    init(selection: Binding<AppDestination?>?, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.content = content()
    }

    var body: some View {
        if let selection {
            List(selection: selection) { content }
        } else {
            List { content }
        }
    }
}

extension View {
    /// A row of a list that may sit beside its detail. With a selection, the selected row gets the
    /// accent wash (rows with their own background don't show the system highlight) and the
    /// selected trait for VoiceOver; without one, the row keeps `background` exactly as before.
    @ViewBuilder
    func selectableRow(_ destination: AppDestination, selection: Binding<AppDestination?>?, background: Color? = nil) -> some View {
        if let selection {
            let isSelected = selection.wrappedValue == destination
            listRowBackground(isSelected ? LumenColor.accentSubtle : background)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else if let background {
            listRowBackground(background)
        } else {
            self
        }
    }
}
