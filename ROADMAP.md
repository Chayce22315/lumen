# Roadmap

Lumen is built in phases. Each phase ships working functionality, integrated with what exists,
with tests, and keeps both CI jobs green. Status reflects what is in the repository today.

## Phase 0 — Infrastructure ✅

- Two packages (portable `LumenKit`, Apple-only `LumenInterface`) and a thin Xcode project.
- Linux toolchain container (Swift 6.1 default, 6.2 checked) and `scripts/lumenkit-linux.sh`.
- CI: LumenKit tests on Linux (Swift 6.1 and 6.2) and macOS; iOS Simulator build of the app.
- `ARCHITECTURE.md`, `DEVELOPMENT.md`, `FILE_STRUCTURE.md`, `CHANGELOG.md`, this roadmap.

## Phase 1 — Foundation ✅

- Typed identifiers, calendar dates, time of day, recurrence rules, hybrid logical clock, JSON
  values, logging, retry/backoff.
- SQLite layer: typed rows, savepoints, namespaced migrations, transactional change log,
  `secure_delete`.
- Core contracts: event bus, action context, settings, Keychain secrets, error reporter.
- Design tokens with WCAG contrast verified by tests.

## Phase 2 — Engines ✅

| Engine | Highlights |
| --- | --- |
| Organization | tasks, subtasks, dependencies, anchored recurrence, reminders, projects with health, calendars with DST-correct recurring events, agenda, natural-language capture |
| Knowledge | notes, Markdown structure, wiki links and backlinks, hashtags, version history with diffs, collections, documents with dedupe |
| Search | FTS5 index with diacritic folding, ranking, snippets, event-driven indexer, history, fuzzy command palette |
| Intelligence | Anthropic and OpenAI-compatible streaming providers, tool loop with approvals, memory, context budgeting, retries, usage |
| Automation | workflow graphs, triggers (manual, events, schedules), conditions, templating, executor with retries and delays, recovery, history |
| Analytics | local event collection, daily aggregates, streaks, distributions, insights, reports |
| Sync | per-field LWW state CRDT over the change log, shadows, conflicts with restore, retry, offline handling, history |
| Notifications | inbox, categories, quiet hours, system delivery |
| Plugins | manifests, capability grants, extension points, lifecycle with rollback |

## Phase 3 — Application and presentation ✅

- Composition root and runtime lifecycle; built-in features registered as plugins.
- Assistant tools and automation actions bridging every engine; approval broker.
- Home: greeting, suggestions, agenda, projects, insights, activity, recent notes, layout editing.
- View models for every screen, unit tested on Linux.

## Phase 4 — iOS interface ✅

- [x] SwiftUI design system and every screen wired to its view model.
- [x] Xcode project, widget extension (Today widget), App Intents (add task, today summary, add note).
- [x] First green `xcodebuild` on CI: app, widget extension and App Intents for the iOS Simulator.
- [x] UI smoke tests (XCUITest target) for launch and every tab, capture, completion, search and the
  unconfigured assistant, run on an iPhone simulator on CI. They found and pinned a real bug:
  completed rows vanished from smart lists a quarter second after the tap.
- [x] App icon (default, dark and tinted), accent color, launch screen in the palette background.

## Phase 5 — Depth ✅

- [x] Sync transport over CloudKit's private database (`CloudSyncTransport` + `CloudKitRecordDatabase`)
  and document file sync. **Switched off** until the build names an iCloud container
  (`LumenCloudKitContainerIdentifier`); that needs an Apple Developer Program team. The transport
  logic is tested against an in-memory database; the CloudKit adapter has not run against iCloud.
- [x] Document previews (QuickLook) and PDF text extraction (PDFKit) for new imports.
- [x] Assistant: model picker per conversation, conversation search, attachments from the library.
- [x] Automations: conditions and delays in the visual editor, drag-to-connect canvas editing,
  undo, run detail with rerun.
- [x] Calendar: create, edit and delete events in system calendars; month view.
- [x] Widgets: check off tasks from the Today widget (queued in the App Group, applied by the app);
  Lock Screen accessories.
- [x] Background refresh (`BGTaskScheduler`): automations, widget actions, sync, widget snapshot and
  document uploads while the app is closed.
- [x] Text for documents imported before their format could be read: a backfill runs once per
  extraction version behind launch and in background refresh, reading only files on the device.

## Free release setup ✅

Lumen is built, tested and used without a paid Apple Developer Program membership (`RELEASE.md`):
simulator and free personal-device signing, unsigned Release IPA from CI, privacy manifests,
export compliance, privacy policy, store listing and screenshots prepared. TestFlight and App Store
distribution are an optional future milestone, never a blocker; no feature depends on them.

## Phase 6 — Platform reach ⏳

- [x] iPad layouts: sidebar navigation (sidebar-adaptable `TabView`), list and detail side by side for
  tasks, projects, notes, conversations and automations; keyboard shortcuts (⌘K palette with arrow
  and Return selection, ⌘N, ⌘⇧N, ⌘F, ⌘,, ⌘1–⌘5) routed through the router and tested on Linux.
- Spotlight indexing of tasks and notes, Live Activities for focus sessions.
- [x] Third-party plugin distribution and review flow: signed declarative `.lumenplugin` packages,
  trust on first use per publisher key, install review with per-capability and per-host grants and
  update diffs; Files, install-link and catalog channels (no built-in catalog, no server).
  See `PLUGINS.md`.
