# File structure

Counts are generated from the repository tree by `scripts/update-file-structure.py` (Swift files);
module descriptions are written by hand.

```
Lumen.xcodeproj/              Xcode project (synchronized folders, shared scheme)
App/Lumen/                    App target: entry point, App Intents, asset catalog (icon, colors)
App/LumenWidgets/             Widget extension: Today widget (interactive), Lock Screen widgets
App/LumenUITests/             XCUITest smoke tests (iPhone), iPad list/detail test, screenshots
App/Configuration/            Base xcconfig (versions, signing, identifiers), Info.plists, entitlements
Packages/LumenKit/            Portable modules (Linux-testable)
Packages/LumenInterface/      SwiftUI modules (Apple only)
Tools/LinuxToolchain/         Pinned Swift toolchain image
Tools/AppIcon/render.py       Renders the app icon variants into the asset catalog (Pillow)
scripts/lumenkit-linux.sh     Build/test LumenKit in the container
scripts/ios-ui-tests.sh       Run the UI smoke tests and screenshot capture on the newest iPhone simulator
scripts/export-screenshots.sh Copy the captured screenshots out of the test results
scripts/build-unsigned-ipa.sh Release build for devices without signing → build/Lumen-unsigned.ipa
scripts/set-version.sh        Set the marketing version and build number
scripts/audit-privacy-apis.sh Check the sources against the privacy manifest
scripts/update-file-structure.py  Refresh the counts in this file
Release/metadata/en-US/       Store listing drafts (name, subtitle, description, keywords)
.github/workflows/ci.yml      CI: Linux 6.1/6.2, macOS tests, iOS Simulator build and UI tests
```

## Packages/LumenKit

| Module | Responsibility | Files | Tests |
| --- | --- | ---: | ---: |
| `CSQLite` | System SQLite module map (Linux only) | 0 | — |
| `LumenAnalytics` | Event collection, aggregates, streaks, insights, reports | 30 | 10 |
| `LumenApplication` | Composition root, runtime, integrations, Home, reminders, widgets, deep links | 25 | 7 |
| `LumenAutomation` | Workflows, triggers, conditions, templates, executor, scheduler | 38 | 16 |
| `LumenCore` | Event bus, action context, settings, secrets (Keychain), errors, configuration | 8 | 3 |
| `LumenDesignTokens` | Palette, spacing, radii, type ramp, motion values, contrast math | 5 | 1 |
| `LumenFoundation` | Identifiers, time, recurrence, hybrid clock, JSON values, logging, retry, text | 16 | 7 |
| `LumenIntelligence` | Providers, SSE transport, assistant engine, tools, memory, usage, attachments, conversation search | 56 | 16 |
| `LumenKnowledge` | Notes, Markdown, links, versions, collections, documents, tags | 42 | 21 |
| `LumenNotifications` | Inbox, preferences, quiet hours, UserNotifications delivery | 6 | 2 |
| `LumenOrganization` | Tasks, projects, calendars, agenda, reminders, quick capture | 26 | 5 |
| `LumenPersistence` | SQLite connection, typed rows, migrations, change log | 9 | 3 |
| `LumenPlugins` | Manifests, capabilities, extension registry, plugin host | 7 | 1 |
| `LumenPresentation` | @Observable view models, router, sidebar sections, commands, date labels | 34 | 9 |
| `LumenSearch` | FTS5 index, ranking, snippets, indexer, history, command registry | 11 | 2 |
| `LumenSync` | Entity-state CRDT, shadows, conflicts, sync engine, cloud transport, document file sync | 10 | 5 |
| `LumenTestSupport` | Test clock, calendar, in-memory environment, event recorder | 3 | — |
| `LumenWidgetData` | Widget snapshot model, widget action queue, shared container | 2 | — |

## Packages/LumenInterface

| Module | Responsibility | Files | Tests |
| --- | --- | ---: | ---: |
| `LumenDesignSystem` | SwiftUI colors, typography, motion, components | 11 | — |
| `LumenPlatform` | EventKit (read/write), CloudKit adapter, PDFKit extraction, background refresh, Keychain/UserNotifications wiring, WidgetKit reloads, shared services | 7 | — |
| `LumenUI` | Screens and navigation | 33 | — |

**Totals:** 379 source files and 108 test files in the packages, plus 7 in the app targets (app, widget, UI tests).

## Module layout

Every engine follows the same internal shape (see `DEVELOPMENT.md`):

```
Sources/LumenX/
  Models/        value types
  Logic/         pure functions
  Schema/        migrations and row mapping
  Repositories/  SQL per aggregate
  Services/      public API, transactions, events
  Events/        event names and entity kinds
```

## Detailed tree

```
Packages/LumenKit/Sources/LumenAnalytics/Events/  (1)
Packages/LumenKit/Sources/LumenAnalytics/Logic/  (12)
Packages/LumenKit/Sources/LumenAnalytics/Models/  (10)
Packages/LumenKit/Sources/LumenAnalytics/Repositories/  (2)
Packages/LumenKit/Sources/LumenAnalytics/Schema/  (2)
Packages/LumenKit/Sources/LumenAnalytics/Services/  (3)
Packages/LumenKit/Sources/LumenApplication/Composition/  (5)
Packages/LumenKit/Sources/LumenApplication/Home/  (4)
Packages/LumenKit/Sources/LumenApplication/Integrations/  (11)
Packages/LumenKit/Sources/LumenApplication/Lifecycle/  (4)
Packages/LumenKit/Sources/LumenApplication/Navigation/  (1)
Packages/LumenKit/Sources/LumenAutomation/Events/  (2)
Packages/LumenKit/Sources/LumenAutomation/Logic/  (11)
Packages/LumenKit/Sources/LumenAutomation/Models/  (11)
Packages/LumenKit/Sources/LumenAutomation/Repositories/  (3)
Packages/LumenKit/Sources/LumenAutomation/Schema/  (2)
Packages/LumenKit/Sources/LumenAutomation/Services/  (9)
Packages/LumenKit/Sources/LumenCore/Configuration/  (1)
Packages/LumenKit/Sources/LumenCore/Errors/  (1)
Packages/LumenKit/Sources/LumenCore/Events/  (2)
Packages/LumenKit/Sources/LumenCore/Secrets/  (2)
Packages/LumenKit/Sources/LumenCore/Settings/  (2)
Packages/LumenKit/Sources/LumenDesignTokens/  (5)
Packages/LumenKit/Sources/LumenFoundation/Concurrency/  (1)
Packages/LumenKit/Sources/LumenFoundation/Errors/  (1)
Packages/LumenKit/Sources/LumenFoundation/Identity/  (3)
Packages/LumenKit/Sources/LumenFoundation/Logging/  (3)
Packages/LumenKit/Sources/LumenFoundation/Text/  (1)
Packages/LumenKit/Sources/LumenFoundation/Time/  (6)
Packages/LumenKit/Sources/LumenFoundation/Values/  (1)
Packages/LumenKit/Sources/LumenIntelligence/Events/  (2)
Packages/LumenKit/Sources/LumenIntelligence/Logic/  (8)
Packages/LumenKit/Sources/LumenIntelligence/Models/  (12)
Packages/LumenKit/Sources/LumenIntelligence/Providers/  (5)
Packages/LumenKit/Sources/LumenIntelligence/Providers/Anthropic/  (3)
Packages/LumenKit/Sources/LumenIntelligence/Providers/OpenAICompatible/  (3)
Packages/LumenKit/Sources/LumenIntelligence/Repositories/  (5)
Packages/LumenKit/Sources/LumenIntelligence/Schema/  (2)
Packages/LumenKit/Sources/LumenIntelligence/Services/  (12)
Packages/LumenKit/Sources/LumenIntelligence/Transport/  (4)
Packages/LumenKit/Sources/LumenKnowledge/Events/  (1)
Packages/LumenKit/Sources/LumenKnowledge/Logic/  (13)
Packages/LumenKit/Sources/LumenKnowledge/Models/  (10)
Packages/LumenKit/Sources/LumenKnowledge/Platform/  (1)
Packages/LumenKit/Sources/LumenKnowledge/Repositories/  (5)
Packages/LumenKit/Sources/LumenKnowledge/Schema/  (2)
Packages/LumenKit/Sources/LumenKnowledge/Services/  (10)
Packages/LumenKit/Sources/LumenNotifications/Models/  (2)
Packages/LumenKit/Sources/LumenNotifications/Platform/  (1)
Packages/LumenKit/Sources/LumenNotifications/Services/  (3)
Packages/LumenKit/Sources/LumenOrganization/Events/  (1)
Packages/LumenKit/Sources/LumenOrganization/Logic/  (10)
Packages/LumenKit/Sources/LumenOrganization/Models/  (5)
Packages/LumenKit/Sources/LumenOrganization/Repositories/  (3)
Packages/LumenKit/Sources/LumenOrganization/Schema/  (1)
Packages/LumenKit/Sources/LumenOrganization/Services/  (6)
Packages/LumenKit/Sources/LumenPersistence/Changes/  (1)
Packages/LumenKit/Sources/LumenPersistence/Core/  (6)
Packages/LumenKit/Sources/LumenPersistence/Schema/  (2)
Packages/LumenKit/Sources/LumenPlugins/Models/  (3)
Packages/LumenKit/Sources/LumenPlugins/Schema/  (1)
Packages/LumenKit/Sources/LumenPlugins/Services/  (3)
Packages/LumenKit/Sources/LumenPresentation/App/  (1)
Packages/LumenKit/Sources/LumenPresentation/Assistant/  (3)
Packages/LumenKit/Sources/LumenPresentation/Automations/  (7)
Packages/LumenKit/Sources/LumenPresentation/Calendar/  (2)
Packages/LumenKit/Sources/LumenPresentation/Home/  (1)
Packages/LumenKit/Sources/LumenPresentation/Insights/  (1)
Packages/LumenKit/Sources/LumenPresentation/Library/  (3)
Packages/LumenKit/Sources/LumenPresentation/Navigation/  (4)
Packages/LumenKit/Sources/LumenPresentation/Notifications/  (1)
Packages/LumenKit/Sources/LumenPresentation/Search/  (1)
Packages/LumenKit/Sources/LumenPresentation/Settings/  (1)
Packages/LumenKit/Sources/LumenPresentation/Support/  (3)
Packages/LumenKit/Sources/LumenPresentation/Tasks/  (6)
Packages/LumenKit/Sources/LumenSearch/Logic/  (4)
Packages/LumenKit/Sources/LumenSearch/Models/  (2)
Packages/LumenKit/Sources/LumenSearch/Schema/  (1)
Packages/LumenKit/Sources/LumenSearch/Services/  (4)
Packages/LumenKit/Sources/LumenSync/Blobs/  (1)
Packages/LumenKit/Sources/LumenSync/Cloud/  (3)
Packages/LumenKit/Sources/LumenSync/Logic/  (1)
Packages/LumenKit/Sources/LumenSync/Models/  (2)
Packages/LumenKit/Sources/LumenSync/Schema/  (1)
Packages/LumenKit/Sources/LumenSync/Services/  (2)
Packages/LumenKit/Sources/LumenTestSupport/  (3)
Packages/LumenKit/Sources/LumenWidgetData/  (2)
Packages/LumenKit/Tests/LumenAnalyticsTests/  (10)
Packages/LumenKit/Tests/LumenApplicationTests/  (7)
Packages/LumenKit/Tests/LumenAutomationTests/  (16)
Packages/LumenKit/Tests/LumenCoreTests/  (3)
Packages/LumenKit/Tests/LumenDesignTokensTests/  (1)
Packages/LumenKit/Tests/LumenFoundationTests/  (7)
Packages/LumenKit/Tests/LumenIntelligenceTests/  (12)
Packages/LumenKit/Tests/LumenIntelligenceTests/Support/  (4)
Packages/LumenKit/Tests/LumenKnowledgeTests/  (21)
Packages/LumenKit/Tests/LumenNotificationsTests/  (2)
Packages/LumenKit/Tests/LumenOrganizationTests/  (5)
Packages/LumenKit/Tests/LumenPersistenceTests/  (3)
Packages/LumenKit/Tests/LumenPluginsTests/  (1)
Packages/LumenKit/Tests/LumenPresentationTests/  (9)
Packages/LumenKit/Tests/LumenSearchTests/  (2)
Packages/LumenKit/Tests/LumenSyncTests/  (5)
Packages/LumenInterface/Sources/LumenDesignSystem/Components/  (6)
Packages/LumenInterface/Sources/LumenDesignSystem/Motion/  (2)
Packages/LumenInterface/Sources/LumenDesignSystem/Tokens/  (3)
Packages/LumenInterface/Sources/LumenPlatform/  (7)
Packages/LumenInterface/Sources/LumenUI/Assistant/  (2)
Packages/LumenInterface/Sources/LumenUI/Automations/  (6)
Packages/LumenInterface/Sources/LumenUI/Calendar/  (2)
Packages/LumenInterface/Sources/LumenUI/Home/  (2)
Packages/LumenInterface/Sources/LumenUI/Insights/  (1)
Packages/LumenInterface/Sources/LumenUI/Library/  (3)
Packages/LumenInterface/Sources/LumenUI/Notifications/  (1)
Packages/LumenInterface/Sources/LumenUI/Root/  (5)
Packages/LumenInterface/Sources/LumenUI/Search/  (2)
Packages/LumenInterface/Sources/LumenUI/Settings/  (3)
Packages/LumenInterface/Sources/LumenUI/Tasks/  (6)
```
