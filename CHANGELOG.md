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
- Linux toolchain container, `scripts/lumenkit-linux.sh`, and CI for Linux and macOS.
- `ARCHITECTURE.md` and `DEVELOPMENT.md`.
