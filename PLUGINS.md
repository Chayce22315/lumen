# Lumen plugins

Third-party plugins extend Lumen with automation templates, commands, assistant shortcuts and
HTTPS webhook steps. iOS doesn't allow apps to load code, so a plugin is **data**: a signed JSON
package that Lumen's own engines execute through the same extension points the built-in features
use. Nothing is installed without the user's review, and every permission and network address is
granted individually.

## Installing

- **Files and the share sheet:** open a `.lumenplugin` file with Lumen.
- **Links:** `lumen://plugin/install?url=<https url>` downloads the package (at most 512 KB,
  30 s idle and 60 s overall timeouts) and opens the review.
- **Catalogs:** add the https URL of a catalog (below) in Settings › Plugins › Catalogs. Lumen
  ships with no catalog and talks to no server of its own.

Every channel leads to the same install review: publisher, signature status and key fingerprint,
each requested capability in plain language, network addresses, every contribution (with
step-by-step previews of automation templates) and, for updates, what changed. Settings › Plugins
turns plugins off, reviews permissions again, shows the source and manifest, and uninstalls (which
also removes the automations added from the plugin).

## Package format (`.lumenplugin`, format version 1)

UTF-8 JSON, at most 512 KB, uniform type `app.lumen.plugin` (conforms to `public.json`):

```json
{
  "format": "app.lumen.plugin",
  "formatVersion": 1,
  "payload": "<base64 of the manifest JSON bytes>",
  "signature": {
    "algorithm": "ed25519",
    "publicKey": "<base64, 32 bytes>",
    "value": "<base64, 64 bytes>"
  }
}
```

The signature is optional and detached: it signs the bytes
`"app.lumen.plugin.signature.v1" + 0x00 + payload`, so no JSON canonicalisation is involved and the
context string separates this use of the key from any other. Unsigned packages install only after
an extra confirmation.

### Manifest

| Field | Rules |
| --- | --- |
| `schemaVersion` | `1` |
| `id` | reverse-DNS; `app.lumen.*` is reserved |
| `name` | at most 60 characters |
| `version` | `x.y.z`; updates must increase it |
| `publisher` | `{ "name": …, "url": "https://…" (optional) }` |
| `description` | at most 1000 characters |
| `minimumLumenVersion` | `x.y.z` |
| `capabilities` | subset of `contributeCommands`, `contributeWorkflowTemplates`, `contributeAssistantPrompts`, `contributeAutomationActions`, `network` |
| `network` | `{ "hosts": [dns names] }` — no IP addresses, `localhost` or `.local`; every host must be used |
| `contributions` | see below |

### Contributions

| Kind | Shape | Needs |
| --- | --- | --- |
| `workflows[]` (≤ 20) | `{ id, name, summary, trigger, graph }` in the automation engine's JSON form, ≤ 50 nodes; validated by the engine; built-in steps and this package's webhook steps only | `contributeWorkflowTemplates` |
| `commands[]` (≤ 40) | `{ id, title, subtitle?, keywords?, action }` with `{ "type": "openLink", "url": "lumen://…" }` (not an install link) or `{ "type": "runWorkflow", "workflow": <id> }` | `contributeCommands` (+ templates for `runWorkflow`) |
| `prompts[]` (≤ 40) | `{ id, title, prompt }`, prompt ≤ 4000 characters | `contributeAssistantPrompts` |
| `webhooks[]` (≤ 10) | `{ id, title, summary?, url, fields: [{ name, title, multiline?, required? }] }`; `url` is https on a declared host, default port, no credentials or fragment | `contributeAutomationActions` + `network` |

Every contribution kind needs its capability, and every requested capability must be used.
Unknown keys and wrong types are refused with their path (for example
`manifest.contributions.commands[2].title`).

A webhook step sends `POST` with `application/json` of its fields to its fixed URL (15 s timeout,
64 KB response limit). 408, 425, 429 and 5xx responses are retried as transient; other non-2xx
responses fail the step.

### Permissions

Capabilities are granted one by one. Denying one withholds exactly the contributions that need
it; granting it later adds them. Webhook steps are offered only for hosts the user allowed, and
revoking a host removes its step.

## Trust

- The key that signed the installed version is pinned (trust on first use per publisher key).
- An update signed by a different key, or an unsigned update of a signed install, is refused.
- Downgrades are refused.
- Installed packages are decoded and verified again at every launch; a package that fails starts
  as failed and can still be uninstalled.
- Logs and events carry plugin ids and versions only, never package text.

## Catalogs

A catalog is a static JSON file at an https URL (a GitHub raw file works), at most 256 KB and
200 entries:

```json
{
  "format": "app.lumen.plugin-catalog",
  "schemaVersion": 1,
  "name": "My plugins",
  "plugins": [
    { "id": "com.example.standup", "name": "Standup", "version": "1.2.0",
      "publisher": "Example", "summary": "Daily standup helpers",
      "url": "https://example.com/standup.lumenplugin",
      "sha256": "<hex digest of the package file>" }
  ]
}
```

A downloaded package must match the listed SHA-256, id and version before it reaches the review.
