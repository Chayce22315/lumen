# Lumen Architecture

Lumen is a personal intelligence and productivity environment for iOS: tasks, projects,
calendar, notes and documents, an AI assistant, visual automations, analytics and universal
search in one application. This document describes how the system is put together and why.

> Powerful beneath the surface, simple on the surface. The complexity belongs in the engineering.

## 1. Shape of the system

```
┌───────────────────────────────────────────────────────────────────────────────┐
│ Xcode targets          Lumen (app)                LumenWidgets (extension)    │
│                        entry point, App Intents   WidgetKit timelines         │
├───────────────────────────────────────────────────────────────────────────────┤
│ Packages/LumenInterface   (SwiftUI, Apple platforms only)                     │
│   LumenDesignSystem   tokens → SwiftUI colors, type, motion, components        │
│   LumenUI             feature screens, navigation, sheets, command palette    │
├───────────────────────────────────────────────────────────────────────────────┤
│ Packages/LumenKit         (portable Swift, builds and tests on Linux)         │
│   LumenPresentation   @Observable view models, formatting                     │
│   LumenApplication    composition root, lifecycle, cross-engine integrations  │
│   ─────────────────────────────────────────────────────────────────────────   │
│   Engines: Organization · Knowledge · Intelligence · Automation · Analytics   │
│            Search · Sync · Notifications · Plugins                            │
│   ─────────────────────────────────────────────────────────────────────────   │
│   LumenCore           events, settings, secrets, errors, configuration        │
│   LumenPersistence    SQLite, migrations, change log                          │
│   LumenFoundation     identifiers, time, recurrence, JSON, logging, retry     │
│   LumenDesignTokens   colors, spacing, type scale, motion values, contrast    │
└───────────────────────────────────────────────────────────────────────────────┘
```

Dependencies point strictly downward. Engines never import each other.

## 2. Modules

| Module | Responsibility | Depends on |
| --- | --- | --- |
| `LumenFoundation` | Typed `Identifier`, `EntityKind`/`EntityReference`, `TimeSource`, `CalendarDate`, `TimeOfDay`, `RecurrenceRule` + calculator, hybrid logical clock, `JSONValue`, logging, retry/backoff, text folding, `PresentableError` | — |
| `LumenPersistence` | `Database` actor over SQLite, typed rows, migrations, savepoints, append-only change log stamped with hybrid timestamps | Foundation (+ `CSQLite` on Linux) |
| `LumenCore` | `EventBus` and `DomainEvent`, `ActionContext`, `SettingsStore`, `SecretStore` (+ Keychain), `ErrorReporter`, `AppConfiguration`, feature flags | Foundation, Persistence |
| `LumenDesignTokens` | Semantic color palette (dark-first, light variant), spacing, radii, type ramp, motion curves, WCAG contrast checks | — |
| `LumenNotifications` | In-app inbox, per-category preferences, quiet hours, system delivery via `UNUserNotificationCenter` | Core |
| `LumenOrganization` | Tasks, projects, calendar events, reminders, recurrence, priorities, dependencies, progress, external calendar source (read and write) | Core |
| `LumenKnowledge` | Notes, documents, collections, tags, wiki links and backlinks, version history, Markdown structure, platform text extractors (`DocumentTextExtractor`; PDFKit on Apple platforms) | Core |
| `LumenSearch` | FTS5 global index, ranking, filters, search history, command palette actions | Core |
| `LumenIntelligence` | Provider abstraction (Anthropic, OpenAI-compatible), streaming, tool calling loop, conversation persistence, memory, context budgeting, retries, token usage, per-conversation model choice, attachments (references resolved through `AttachmentResolver`), conversation search (FTS5) | Core |
| `LumenAutomation` | Workflow graphs, triggers, conditions, templating, execution, scheduling, run history, recovery | Core |
| `LumenAnalytics` | Local event collection, daily aggregates, productivity insights, comparisons, reports | Core |
| `LumenSync` | Local-first sync over the change log: per-field LWW entity states, transport abstraction, the cloud transport over `CloudRecordDatabase`, document file sync by SHA-256, conflict records, retry queue, remote-reset recovery, history | Core |
| `LumenPlugins` | Plugin manifests, capability declarations, permission grants, lifecycle, packages, signatures, trust, catalogs | Core, extension protocols of the engines it hosts |
| `LumenWidgetData` | The snapshot the widget renders, the widget action queue, the shared App Group location | — |
| `LumenApplication` | Composition root, bootstrap and shutdown, built-in features registered as plugins (assistant tools, automation actions and triggers, search sources, sync handlers, commands), Home, reminders, widget snapshot, deep links | all engines |
| `LumenPresentation` | `@Observable` view models for every screen, router, date labels | Application |
| `LumenDesignSystem` | SwiftUI rendering of the tokens, components, motion, haptics | DesignTokens |
| `LumenPlatform` | Apple adapters: EventKit calendar source (read and write), CloudKit record database (only for builds with an iCloud container), PDFKit text extraction, background refresh, Keychain and UserNotifications wiring, WidgetKit reloads, the shared services and runtime | Application |
| `LumenUI` | Screens, navigation, sheets, command palette | Presentation, DesignSystem, Platform |

## 3. Decisions

Each decision records the alternatives and why the default was chosen.

### D1 — SQLite with an owned data layer instead of SwiftData

*Alternatives:* SwiftData; Core Data; a third-party SQLite library.

*Chosen:* a small SQLite layer (`LumenPersistence`, ~800 lines) over the system SQLite.

*Why:* universal search needs FTS5 ranking, which SwiftData cannot express; local-first sync needs
an append-only change log written in the same transaction as the data, which requires explicit
transactions; migrations must be explicit and testable; and the engines must build and test on
Linux, where SwiftData does not exist. A third-party library was rejected to keep the dependency
list empty. *Cost:* hand-written SQL per repository, which is contained by the module layout rules.

### D2 — Two packages: portable `LumenKit` and Apple-only `LumenInterface`

*Why:* everything with business meaning — including view models — compiles without SwiftUI, so
it is verified by `swift test` on any machine and on CI's Linux job. The interface package is
only built by Xcode for iOS. The app and widget targets are thin shells over the packages.

### D3 — Engines are independent; `LumenApplication` integrates them

Each engine exposes extension protocols (`AssistantTool`, `AutomationAction`,
`AutomationTriggerSource`, `SearchableSource`, `SyncEntityHandler`). The application layer
adapts one engine to another (for example, an `AssistantTool` that creates a task through
`TaskService`). Built-in features are registered the same way third-party plugins would be,
which keeps the plugin architecture honest.

### D4 — Events after commit, change records inside the transaction

A write is `database.write { row + change record }` followed by `events.publish(...)`. The change
log is therefore never out of step with the data (sync correctness), while event subscribers
(search indexer, analytics, automation triggers, widget snapshot, view models) are eventually
consistent and can always be rebuilt from storage.

### D5 — Hybrid logical clocks and a per-field last-writer-wins state CRDT

*Alternatives:* whole-entity last-writer-wins; snapshot three-way merge against a stored base.

*Chosen:* every synchronized entity is represented on the wire as an `EntityState`: a map of
fields, each with the hybrid timestamp (physical time + logical counter + replica id) of the change
that last set it, plus a deletion tombstone. Merging takes the newer timestamp per field and the
newer tombstone; an entity is deleted when its tombstone is at least as new as every field.

*Why:* the merge is commutative, associative and idempotent, so every replica converges whatever
order changes arrive in, and the server can be a dumb ordered log. A snapshot three-way merge was
implemented first and rejected: with push-then-pull ordering, a concurrent edit to a different
field on another device could be silently overwritten. Field timestamps are derived exactly from
the change log (each local change is diffed against the record before it), so a field a device
did not touch can never overwrite a newer remote edit. Shadows remember, per replica, the newest
write observed for each entity; a conflict is recorded only when a write that was genuinely new to
this device lost to a different value, and the losing value can be restored from Settings.

### D6 — Settings are device-local; secrets are Keychain-only

Settings describe this device (layout, model choice, notification preferences) and are not
synchronized. Secrets are stored only through `SecretStore`, backed by the Keychain with
`AfterFirstUnlockThisDeviceOnly`, and never logged, synchronized or exported.

### D7 — Deployment target iOS 18

iOS 18 provides the zoom navigation transition (`matchedTransitionSource` /
`navigationTransition(.zoom)`) used for shared-element transitions, the `Tab` API, `Mutex` from
the Synchronization module, and mature Observation. Supporting iOS 17 would require
hand-built fallbacks for all of these.

### D8 — Sync transports talk to a small record-database protocol

`CloudSyncTransport` holds all sync transport logic (one record per entity carrying its merged
`EntityState`, merge on change-tag conflicts, batching within CloudKit's request limits, assets for
large states, change tokens, full refetch when a token expires, remote-reset recovery) against
`CloudRecordDatabase`, which CloudKit implements in the app and an in-memory fake implements in
tests. The Apple adapter only translates. The adapter is created only when the build names an iCloud
container, because touching `CKContainer` without the entitlement terminates the app.

### D9 — The widget extension never opens the database

Widgets have tight memory limits and a second process writing SQLite invites contention. A
checkbox in the widget appends to `WidgetActionQueue` (a bounded JSON file in the App Group,
written atomically under `flock`) and updates the snapshot optimistically; the app applies the
queue through `TaskService` in `LumenRuntime.applyWidgetActions()` on start, on activation and in
background refresh.

### D10 — One router, two layouts

`Router` (LumenPresentation) is the single source of navigation truth. The root is a
sidebar-adaptable `TabView` whose structure follows `Router.layout`: `.tabBar` (iPhone, compact
iPad: five tabs, each a stack) or `.sidebar` (regular-width iPad: `NavigationSection` items,
list/detail sections as `NavigationSplitView`). Each section's place is one `[AppDestination]`
path; list/detail sections keep their selection first and the detail stack after it, so
`setLayout(_:)` converts state across size-class changes without loss. Menu commands and keyboard
shortcuts are `AppCommand` values performed by `AppModel.perform` → `Router.perform`, so the
keyboard is tested on Linux like every other way into the app.

### D11 — Third-party plugins are declarative packages

*Alternatives:* downloaded code (not allowed on iOS); a scripting runtime such as JavaScriptCore
(a large attack surface for little gain).

*Chosen:* signed JSON packages (`PLUGINS.md`) whose contributions — automation templates, commands,
assistant shortcuts, HTTPS webhook steps — are executed by Lumen's own engines through the same
extension points the built-in features use. `LumenPlugins` owns the format, validation, trust and
lifecycle (`PluginPackageManager` over `PluginHost`) without importing another engine;
`LumenApplication` supplies the integration that validates templates with the automation engine,
resolves deep links and removes owned entities on uninstall. Capabilities are granted one by one
and a plugin activates once its required capabilities are granted.

## 4. Data flow

```
View ──intent──▶ ViewModel ──▶ Service.method(context:)
                                   │
                                   ├─ validate (pure Logic)
                                   ├─ database.write { repository.save(row); recordUpsert(snapshot) }
                                   └─ events.publish(DomainEvent)
                                                │
              ┌─────────────────┬───────────────┼────────────────┬─────────────────┐
              ▼                 ▼               ▼                ▼                 ▼
       Search indexer     Analytics      Automation triggers   Widget snapshot   ViewModels refresh
```

## 5. Concurrency

- `Database` is an actor; work runs in synchronous closures so a transaction can never suspend
  half-way.
- Services are `final class … : Sendable` holding only immutable references (database, event bus,
  time source); they have no mutable state of their own, or protect it with `Mutex`.
- Long-running engines with lifecycle (automation scheduler, sync coordinator, search indexer)
  are actors.
- View models are `@MainActor @Observable`.
- Cancellation propagates through structured concurrency: closing the assistant sheet cancels the
  streaming task, which cancels the HTTP request.

## 6. Error handling

Errors are typed per module. Anything that reaches the interface is converted to an
`ErrorPresentation` (title, message, recovery suggestion, retryability). Unhandled errors go
through `ErrorReporter`, which logs them, keeps them for the diagnostics screen and streams them to
the interface as non-blocking banners.

## 7. Security and privacy

- No API keys in source, configuration files, the database or logs. Keys entered by the user go
  straight to the Keychain.
- Analytics are local only; nothing leaves the device unless the user configures a model provider
  (requests go directly to that provider) or a sync transport.
- Log messages never contain user content.
- Plugins declare capabilities; each capability is granted explicitly by the user and enforced
  by the permission-checked context the plugin receives. Third-party packages are validated
  strictly before anything is stored, their publisher key is pinned on first install, network
  access is granted per host, packages are re-verified at every launch, and no package text is
  logged.

## 8. The assistant and automations act through the same services

Assistant tools (`create_task`, `search_lumen`, `get_agenda`, `run_workflow`, …) and automation
actions (`organization.createTask`, `knowledge.appendToNote`, `notifications.send`, …) are thin
adapters over the same services the interface uses, so validation, events, analytics, search
indexing, reminders and sync behave identically whoever acts. Events carry the actor
(`assistant`, `automation`), which keeps analytics honest and lets automations ignore their own
output beyond a causation depth. Mutating assistant tools wait for the user's approval through
`ToolApprovalBroker` unless the user turned approval off; with no interface attached the answer
is "no". Attachments are resolved by the application layer (`KnowledgeAttachmentResolver`), so the
intelligence engine never reads knowledge tables.

## 9. Testing strategy

| Layer | How it is verified |
| --- | --- |
| Pure logic (recurrence, ranking, merge, parsing, insights, contrast) | Exhaustive unit tests |
| Repositories and services | Integration tests on in-memory SQLite with a manual clock |
| Providers and transports | Recorded/fake transports; SSE parsing tested byte-for-byte |
| View models | Unit tests on Linux with fake services |
| Interface | Built for the iOS Simulator on CI; XCUITest smoke tests drive the real app on an in-memory store (`-LumenUITesting`); previews use in-memory composition |
