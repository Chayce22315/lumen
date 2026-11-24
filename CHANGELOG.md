# Changelog

All notable changes to Lumen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `LumenKit` Swift package with the portable foundation of the app.
- `LumenFoundation`: typed identifiers, entity references, calendar dates, time of day,
  recurrence rules and calculator, hybrid logical clock, JSON values, logging system with
  ring-buffer and unified-logging sinks, retry policy with backoff and jitter, text folding,
  presentable errors.
- `LumenPersistence`: `Database` actor over SQLite with typed rows, savepoint-based nested
  transactions, namespaced forward-only migrations and an append-only change log stamped with
  hybrid timestamps.
- `LumenCore`: event bus with filtered subscriptions, action context for causation tracking,
  SQLite-backed typed settings, Keychain secret store, error reporter, app configuration.
- `LumenNotifications`: in-app inbox, per-category preferences, quiet hours and
  `UNUserNotificationCenter` delivery.
- Linux toolchain container, `scripts/lumenkit-linux.sh`, and CI for Linux (Swift 6.1 and 6.2)
  and macOS.
- `LumenDesignTokens`: semantic palette (dark-first with light variants), spacing, radii, type
  ramp, motion values; WCAG contrast verified by tests.
- `LumenOrganization`: tasks with priorities, due dates and times, deferral, subtasks, tags,
  dependencies with cycle detection, anchored recurrence and reminders; projects with progress
  and health; calendars with DST-correct recurring events and an external calendar source;
  agenda and today overview; natural-language quick capture.
- `LumenKnowledge`: notes with Markdown structure, wiki links, backlinks and hashtags; version
  history with line diffs; collections; documents with SHA-256 dedupe and text extraction; tags.
- `LumenSearch`: FTS5 index with diacritic folding, bm25 + title + recency ranking, snippets with
  highlights, event-driven indexer, search history, fuzzy command palette.
- `LumenIntelligence`: provider abstraction with Anthropic and OpenAI-compatible streaming
  providers, SSE parsing, tool calling loop with approval, memory, context budgeting, retries,
  token usage, conversation persistence.
- `LumenAutomation`: workflow graphs, manual/event/schedule triggers, conditions, templates,
  executor with retries and delays, interrupted-run recovery, history, graph editing and layout.
- `LumenAnalytics`: local event collection, daily aggregates, streaks, distributions, insights
  and period reports.
- `LumenSync`: per-field last-writer-wins entity states over the change log, shadows with
  observed-write tracking, conflict review and restore, retry and offline handling, history.
- `LumenPlugins`: manifests, capability grants, typed extension points, lifecycle with rollback
  and activation timeout.
- `LumenApplication`: composition root and runtime; built-in features as plugins; assistant tools
  and automation actions over every engine; approval broker; Home with greeting, suggestions and
  customizable layout; reminders; widget snapshot; deep links.
- `LumenPresentation`: observable view models for every screen.
- `LumenInterface`: SwiftUI design system, platform adapters and all screens; Xcode project with
  app target, Today widget and App Intents.
- `ARCHITECTURE.md`, `DEVELOPMENT.md`, `ROADMAP.md`, `FILE_STRUCTURE.md`.
- `LumenUITests` XCUITest target with smoke tests for launch, every tab, quick capture, completing
  a task from its checkbox and finding it in search; `scripts/ios-ui-tests.sh` and a CI step that
  runs them on an iPhone simulator.
- `LaunchMode`: Debug builds started with `-LumenUITesting` run on an empty in-memory store with
  in-memory secrets, no system notifications and no network.
- Quick capture has a Close button.
- Sync over CloudKit's private database (`CloudSyncTransport`, `CloudKitRecordDatabase`): one record
  per entity holding its merged state, merges on change-tag conflicts, batching within CloudKit's
  limits, assets for large states, change tokens with full refetch on expiry, recovery when the
  remote store is reset. Switched off until the build names an iCloud container
  (`LumenCloudKitContainerIdentifier`).
- Document file sync: files upload once per SHA-256 and download on first read, verified.
- Background app refresh (`app.lumen.refresh`): automations, widget actions, sync, widget snapshot
  and document uploads while the app is closed; the interface and background refresh share one
  runtime.
- Assistant: choose a model per conversation (only configured providers are offered); search
  conversations by title and message text with highlighted matches; attach notes and documents to
  a message (stored as references, re-read on each request, cut to a budget and labelled when cut).
- Documents: QuickLook preview when the file is on the device; PDF text extraction (PDFKit) makes
  imported PDFs searchable and attachable. Documents imported before their format could be read
  get their text once per extraction version (`DocumentService.extractMissingText`, run behind
  launch and in background refresh; only files on the device are read).
- Visual automation editor: conditions with typed rules and true/false branches, delays (up to 30
  days), adding steps after any output, connecting and disconnecting outputs, undo, refusals that
  explain why. The diagram moves steps by touch-and-hold then drag (snapped to a grid), connects by
  dragging from an output dot, removes connections by tapping them; every diagram action is also
  in each step's menu and its accessibility actions.
- Run detail: each step's branch, inputs, output, timing, retries, warnings and errors; run again;
  stop a running run. Run steps keep their resolved inputs (migration
  `automation/0002_run_step_inputs`); `AutomationEngine.rerun`.
- Create, edit and delete events in system calendars from the event editor, with honest access
  handling, notes where the system calendar repeats differently, and rules and alerts Lumen can't
  edit kept intact; read-only calendars open as view-only.
- Month view in the Calendar screen with event and task dots and a VoiceOver label per day.
- Check off tasks from the Today widget: the completion is queued in the App Group and applied by
  the app; the widget updates immediately. Lock Screen widgets: progress ring, tasks left with the
  next task, inline summary.
- App icon (default, dark and tinted appearances) rendered by `Tools/AppIcon/render.py`; accent
  color and a launch screen in the palette's background color, so launch no longer flashes white.

- iPad: a sidebar (sidebar-adaptable tab view) with Home, Plan's smart lists with open-task counts,
  Projects, Calendar, Automations, the Library and its collections, the Assistant, Insights, Search
  and Settings. Task lists, projects, notes, conversations and automations show their list beside
  the selected item. iPhone and compact-width iPad keep the tab bar; your place carries across when
  the window is resized. Pointer hover effects.
- Keyboard shortcuts, listed in iPad's ⌘-hold overlay: ⌘K command palette, ⌘N new task, ⌘⇧N new
  note, ⌘F find, ⌘, Settings, ⌘1–⌘5 sections. In the palette, ↑/↓ choose a row, Return opens it.
- Focus sessions: focus on a task (or nothing in particular) for a chosen length; pause, resume,
  finish or cancel; optionally complete the task when done. Start from Home, a task row (swipe or
  context menu), task details, Shortcuts or Siri ("Start Focus"/"Stop Focus"), the assistant
  (`start_focus`/`stop_focus`) or automations (`organization.startFocus`/`stopFocus`, plus a
  focus-completed trigger). Sessions are computed from their timestamps, so they survive relaunch;
  an alert fires when the countdown ends, focused minutes appear in Insights and task details.
- Live Activities for focus sessions on the Lock Screen and in the Dynamic Island (compact,
  minimal, expanded) with pause, resume and finish buttons. Local only — no push, no special
  capability.
- Spotlight: open tasks and notes (title and a short snippet, never a full note) are indexed on
  the device and open in Lumen from search results; Settings › Show in Spotlight turns it off and
  removes everything from the index.
- Third-party plugins: install `.lumenplugin` packages from Files, the share sheet,
  `lumen://plugin/install?url=…` links or catalogs you add. An install review shows the publisher,
  the signature and its key fingerprint, every permission in plain language, network addresses,
  everything the plugin adds (with step-by-step automation previews) and what an update changes;
  grant or deny each permission and address individually. Settings › Plugins turns plugins off,
  reviews permissions again, shows source and manifest, and uninstalls them (removing the
  automations added from them). Plugins add automation templates, commands, assistant shortcuts and
  HTTPS webhook steps; they never run code. Format and trust rules: `PLUGINS.md`.
- Free release setup (no paid Apple Developer Program needed): signing, versions and identifiers
  in `App/Configuration/Lumen.xcconfig` with a git-ignored `Signing.local.xcconfig` for your team
  and bundle prefix; the App Group follows the prefix and can be switched off for teams that can't
  provision it; privacy manifests with an audit script; export-compliance key; privacy policy;
  store listing drafts; screenshot capture from sample content in UI tests; a Release device build
  and unsigned IPA on every CI run. See `RELEASE.md`.

### Changed
- Third-party plugins are enabled by default (`FeatureFlag.defaults`); the flag remains a kill
  switch.

### Fixed
- Editing an existing automation flattened its graph into a linear chain (dropping branches), turned
  non-daily schedules into daily ones and removed event-trigger conditions. The editor now edits the
  stored graph and keeps triggers it can't change in place.
- The document detail screen no longer hides load errors.
- Completing a task in a smart list (Inbox, Today, Upcoming, Anytime) or a tag list made the row
  vanish on the next refresh, a quarter second later, cutting off the checkmark and the chance to
  undo. Completed rows now stay checked in place until the list is left, as they already did in
  projects. Found by the UI smoke test.
- Plan's list counts were loaded once by the view and never refreshed after a capture or
  completion; a `PlanViewModel` now owns them, follows task events and reports load errors.
- A subscriber feedback loop: the reminder coordinator re-triggered itself through notification
  events (found by the end-to-end test; listeners are now scoped to their owning modules).
- `DatabaseConnection.scalar` returns `nil` for NULL aggregates instead of a type error.
