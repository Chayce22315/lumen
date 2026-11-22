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

## Phase 4 — iOS interface ⏳ (in progress)

- [x] SwiftUI design system and every screen wired to its view model.
- [x] Xcode project, widget extension (Today widget), App Intents (add task, today summary, add note).
- [x] First green `xcodebuild` on CI: app, widget extension and App Intents for the iOS Simulator.
- [ ] UI smoke tests (XCUITest target) for launch, capture, completion and search, run on CI.
- [ ] App icon and launch polish.

## Phase 5 — Depth

- Sync transport: CloudKit private database implementation of `SyncTransport` (requires an Apple
  developer team and iCloud container), plus document blob sync.
- Document previews (QuickLook) and text extraction for PDFs (PDFKit).
- Assistant: model picker per conversation, conversation search, attachments from the library.
- Automations: conditions and delays in the visual editor (the engine already supports them),
  drag-to-connect canvas editing, run detail screen.
- Calendar: create events in system calendars, month view.
- Widgets: interactive completion (App Intents in widgets), lock screen accessories.
- Background refresh (`BGTaskScheduler`) for schedules and sync while the app is closed.

## Phase 6 — Platform reach

- iPad layouts (sidebar navigation), keyboard shortcuts for the command palette.
- Spotlight indexing of tasks and notes, Live Activities for focus sessions.
- Third-party plugin distribution and review flow (the host and permission model exist).
