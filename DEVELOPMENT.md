# Developing Lumen

This is the working agreement for everyone who touches the codebase. `ARCHITECTURE.md` explains
*why* the system is shaped the way it is; this file explains *how* to work inside it.

## Requirements

| Tool | Version | Used for |
| --- | --- | --- |
| Xcode | 16.0 or newer (Swift 6 toolchain, iOS 18 SDK) | the app, widgets, interface package |
| Docker | any recent engine | building and testing `LumenKit` on Linux |
| Swift | 6.0+ (tools version 6.0, Swift 6 language mode) | everything |

No third-party dependencies are used. Adding one requires a written justification in
`ARCHITECTURE.md` under *Decisions*.

## Repository layout

```
Lumen.xcodeproj           App + widget extension targets (thin shells)
App/Lumen/                App target sources: entry point, App Intents, assets, Info.plist
App/LumenWidgets/         Widget extension sources
Packages/LumenKit/        Portable modules: engines, application layer, view models (Linux-testable)
Packages/LumenInterface/  SwiftUI design system and feature screens (Apple platforms only)
Tools/LinuxToolchain/     Pinned Linux toolchain image
scripts/                  Developer scripts
```

See `FILE_STRUCTURE.md` for the module-by-module map.

## Building and testing

### LumenKit on Linux (any machine with Docker)

```sh
scripts/lumenkit-linux.sh build
scripts/lumenkit-linux.sh test
scripts/lumenkit-linux.sh test --filter LumenOrganizationTests
```

The script builds `Tools/LinuxToolchain` (Swift + SQLite headers) on first use and keeps Linux
build products in `.build-linux/<version>/`, separate from Xcode's. The default toolchain is
**Swift 6.1**, the oldest compiler Lumen supports (it matches Xcode 16.4, and its concurrency
checking is stricter in places than newer compilers). Check against a newer compiler with:

```sh
LUMEN_SWIFT=6.2 scripts/lumenkit-linux.sh test
```

### LumenKit on macOS

```sh
swift test --package-path Packages/LumenKit
```

### The app

Open `Lumen.xcodeproj`, select the **Lumen** scheme and an iOS 18+ simulator, then build.

To run on a device, set your team on both targets (Signing & Capabilities). The app and the widget
share data through the App Group `group.app.lumen` (`App/Configuration/*.entitlements` and
`SharedContainer.appGroupIdentifier`); change both if you use another identifier. Without a
provisioned App Group the app falls back to its own container and the widget shows its
"open Lumen" state.

The assistant needs an API key for Anthropic or OpenAI, entered in Settings › Assistant; it is
stored only in the Keychain.
From the command line:

```sh
xcodebuild -project Lumen.xcodeproj -scheme Lumen \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

### Continuous integration

`.github/workflows/ci.yml` runs on every push:

- **linux** — `swift test` for LumenKit in Swift 6.1 and 6.2 containers.
- **apple** — `swift test` for LumenKit on macOS (exercises the Apple-only code paths such as the
  SDK SQLite module and Keychain), then an `xcodebuild` of the app for the iOS Simulator.

A change is not done until both jobs are green.

## Code conventions

### Language

- Swift 6 language mode with complete concurrency checking. `ExistentialAny` is enabled: write
  `any Protocol` for existentials.
- No force unwraps (`!`), `try!` or `as!` in production code. Where a value is provably present,
  restructure so the compiler can see it, or fall back explicitly with a comment explaining why
  the fallback is unreachable.
- No `@unchecked Sendable` unless the type wraps a lock-protected resource and the comment says so.
  Prefer `Synchronization.Mutex` and actors.
- Value types for models: `struct`, `Sendable`, `Hashable`, `Codable`, `Identifiable`.
- Identifiers are typed: `typealias ID = Identifier<TaskItem>`. Never pass raw `UUID`s across
  module boundaries except inside `EntityReference`.
- All-day values use `CalendarDate`; wall-clock times use `TimeOfDay`; instants use `Date`.
- Time comes from an injected `TimeSource`, calendars are injected. Nothing reads `Date()` or
  `Calendar.current` directly outside the composition root.

### Module layout

Every engine module in `LumenKit` follows the same shape:

```
Sources/LumenX/
  Models/        Value types. No I/O.
  Logic/         Pure functions: calculators, parsers, rankers, validators. Heavily tested.
  Schema/        `DatabaseSchema` (migrations) and row ⇄ model mapping.
  Repositories/  SQL for one aggregate. Synchronous functions taking a `DatabaseConnection`.
  Services/      The module's public API. Owns business rules, transactions and event publishing.
  Events/        `EventName` and `EntityKind` constants owned by the module.
```

One responsibility per file. Files that grow beyond ~400 lines are split along a real seam.

### Engines do not depend on each other

An engine (Organization, Knowledge, Automation, Intelligence, Analytics, Search, Sync,
Notifications, Plugins) depends only on `LumenFoundation`, `LumenPersistence` and `LumenCore`.
Cross-engine behaviour — the assistant creating tasks, automations writing notes, search
indexing everything — is wired in `LumenApplication` through the extension protocols each engine
exposes (`AssistantTool`, `AutomationAction`, `SearchableSource`, …).

### Persistence rules

- Each module owns its tables and its `DatabaseSchema` namespace. No module reads another
  module's tables.
- Migrations are append-only. Never edit or reorder a shipped migration; add a new one.
- Table names are prefixed by the module (`organization_tasks`, `knowledge_notes`).
- Every mutation of a synchronized entity goes through its repository's `save`/`delete`, which
  writes the row **and** calls `recordUpsert`/`recordDeletion` in the same transaction.
  Repositories also expose `upsertRow`/`deleteRow` (no change record) for the sync engine.
- Snapshots in the change log are the model's `Codable` form. New model fields must decode with
  defaults (`decodeIfPresent`) so older snapshots stay readable.
- Dates are stored as REAL seconds since 1970, identifiers as TEXT, JSON as TEXT.

### Events

- Publish domain events **after** the transaction commits, never inside it.
- Names are `<module>.<entity>.<verb>` (`organization.task.completed`) and never change once
  shipped: analytics history and saved automations reference them.
- Attributes are small and display-safe (identifiers, statuses, counts) — never note bodies or
  prompts.
- Services take an `ActionContext` so events carry the right actor and causation depth.

### Errors

- Throw typed errors. Errors that reach the user conform to `PresentableError`.
- Never swallow an error. A `catch` either recovers (and says how in a comment), rethrows, or
  reports through `ErrorReporter` / logs at `.error`.
- `try?` is allowed only where failure is an expected, handled outcome (probing, best-effort
  cleanup) and the line says so.

### Logging

- Use the injected `Logger` (category = module). Messages describe system behaviour.
- Never log user content (titles, bodies, prompts, model output) or secrets.

### Secrets

- API keys and tokens live only in `SecretStore` (Keychain in production). They are never
  written to SQLite, settings, logs, analytics, crash reports or source.

### Interface code

- Views are thin: they render view-model state and forward intents. No business rules,
  persistence or networking in `LumenInterface`.
- View models live in `LumenPresentation` (portable, `@Observable`, `@MainActor`) and are unit
  tested on Linux.
- Every control has an accessibility label; every screen supports Dynamic Type up to the
  accessibility sizes; motion respects Reduce Motion.
- No control is shown for functionality that does not exist. Features that need configuration
  (an API key, a sync account) show an honest empty state explaining what to set up.

## Tests

- Swift Testing (`import Testing`) for unit and integration tests; XCTest for performance
  measurements.
- Each engine has a test target exercising its pure logic and its services against an in-memory
  database (`CoreTestEnvironment.make(schemas:)`).
- Tests use `ManualTimeSource` and `Calendar.testUTC`; they never depend on the wall clock or
  the machine's time zone.
- Tests must not touch the network or the real Keychain.

## Commits

- Small, focused commits with an imperative subject line.
- Every commit builds and passes `scripts/lumenkit-linux.sh test`.
- Update `CHANGELOG.md` (Unreleased section) and the relevant architecture docs in the same
  change as the code.
