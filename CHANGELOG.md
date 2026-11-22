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
- App icon (default, dark and tinted appearances) rendered by `Tools/AppIcon/render.py`; accent
  color and a launch screen in the palette's background color, so launch no longer flashes white.

### Fixed
- Completing a task in a smart list (Inbox, Today, Upcoming, Anytime) or a tag list made the row
  vanish on the next refresh, a quarter second later, cutting off the checkmark and the chance to
  undo. Completed rows now stay checked in place until the list is left, as they already did in
  projects. Found by the UI smoke test.
- Plan's list counts were loaded once by the view and never refreshed after a capture or
  completion; a `PlanViewModel` now owns them, follows task events and reports load errors.
- A subscriber feedback loop: the reminder coordinator re-triggered itself through notification
  events (found by the end-to-end test; listeners are now scoped to their owning modules).
- `DatabaseConnection.scalar` returns `nil` for NULL aggregates instead of a type error.
