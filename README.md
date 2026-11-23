# lumen

lumen plus lumen equals illumination🤯

Lumen is a native iOS personal intelligence and productivity environment: tasks, projects and
calendar, notes and documents, an AI assistant that can act on all of them, visual automations,
local analytics and universal search — in one app with a calm, dark-first interface.

## What's inside

- **Organization** — tasks with natural-language capture ("Call Sam tomorrow at 5pm !high"),
  subtasks, dependencies, repeating schedules, reminders; projects with progress and health;
  calendars merged with the system calendar.
- **Knowledge** — Markdown notes with `[[links]]`, backlinks, #tags and version history;
  collections; imported documents.
- **Assistant** — Anthropic or OpenAI models (your own API key, stored in the Keychain) with tools
  to search, plan, create tasks and notes and run automations, asking before it changes anything.
- **Automations** — workflows triggered by events or schedules, built from steps.
- **Insights** — on-device activity, streaks, trends and weekly reports.
- **Search** — one palette for every item and every command.
- **Local-first** — everything is stored in SQLite on the device; a conflict-free sync engine is
  ready for a transport.

## Getting started

```sh
open Lumen.xcodeproj          # scheme "Lumen", any iOS 18+ simulator
scripts/lumenkit-linux.sh test  # or: swift test --package-path Packages/LumenKit
```

No paid Apple Developer Program membership is needed: Lumen runs in the simulator with no account
and on your own iPhone with a free Apple ID — see [RELEASE.md](RELEASE.md).

See [DEVELOPMENT.md](DEVELOPMENT.md) for requirements and conventions,
[ARCHITECTURE.md](ARCHITECTURE.md) for how the system fits together,
[ROADMAP.md](ROADMAP.md) for what's next, [FILE_STRUCTURE.md](FILE_STRUCTURE.md) for the map and
[PLUGINS.md](PLUGINS.md) for writing plugins.
