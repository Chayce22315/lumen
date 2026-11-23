# Lumen privacy policy

Lumen is a personal app that keeps your information on your device. This policy describes what
the app does with data. It applies to the app as built from this repository.

## What Lumen stores

Your tasks, projects, calendar events, notes, documents, automations, conversations with the
assistant, settings and usage insights are stored on your device in the app's own storage (and in
an App Group container shared with Lumen's widgets). Lumen has no account system and no server.

## What leaves your device

Nothing, unless you turn on one of these:

- **Model providers.** If you add an API key for Anthropic or an OpenAI-compatible service, the
  messages you send to the assistant, the context you attach (notes, documents, tasks it looks up)
  and tool results are sent directly from your device to that provider, under that provider's
  terms and privacy policy. Lumen's developer does not receive them. API keys are stored only in
  your device's Keychain.
- **iCloud sync.** In builds with iCloud sync turned on, your data is stored in your own private
  iCloud database, which only your Apple Account can read. Lumen's developer cannot access it.
- **Plugins you install.** A plugin can contact a web address only if its manifest declares the
  host and you grant that permission during installation; you can revoke it at any time. Plugins
  are data run by Lumen itself, never code.
- **System features you use.** Calendar access (to show and create events in your system
  calendars), notifications, widgets and Shortcuts are handled by iOS on your device.

## Analytics and tracking

Lumen does not track you, does not use advertising identifiers, and does not include third-party
analytics or crash-reporting services. The insights screen is computed on your device from your
own data and never sent anywhere. Logs never contain the content of your tasks, notes or messages.

## Deleting your data

Deleting the app deletes all of its data on the device. Data in iCloud (if sync was turned on) can
be removed in Settings › [your name] › iCloud › Manage Storage.

## Children

Lumen is a general productivity app and is not directed at children.

## Changes

Changes to this policy are recorded in this file's history in the repository.
