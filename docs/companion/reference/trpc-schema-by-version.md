# Companion tRPC Schema — Version Differences

Notes on tRPC contract changes between Companion versions, encountered
during real msn-saitama production deploy. Used by
`apps/companion/scripts/companion-deploy.py` to send the right payload
shape for the version of Companion it's targeting.

## Version detection

GET `/int/export/full` returns gzipped JSON whose `companionBuild`
field is the running version (e.g. `"4.2.6+8823-stable-..."`,
`"4.3.1+9209-stable-..."`). Strip the `+` suffix and compare with
semver.

For runtime version detection inside companion-deploy.py: query the
HTTP root, grep for `companion@<version>` in the HTML, OR use the full
export's `companionBuild` field. The script defaults to the more
forgiving 4.3 payload shape if version detection fails — 4.3+ is the
forward direction.

---

## importExport.importFull mutation

Schema source: `shared-lib/lib/Model/ImportExport.ts:11`
(`zodClientImportOrResetSelection`).

### 4.2

```jsonc
{
  "config": {
    "buttons":          "reset-and-import" | "reset" | "unchanged",
    "surfaces":         { "known": "unchanged" | "reset" | "reset-and-import" },
    "triggers":         "reset-and-import" | "reset" | "unchanged",
    "customVariables":  "reset-and-import" | "reset" | "unchanged",
    "expressionVariables": "reset-and-import" | "reset" | "unchanged",
    "connections":      "reset" | "unchanged",
    "userconfig":       "reset" | "unchanged"
  }
}
```

`surfaces` accepts only the `known` key.

### 4.3

```jsonc
{
  "config": {
    "buttons":          "reset-and-import" | "reset" | "unchanged",
    "surfaces": {
      "known":     "reset-and-import" | "reset" | "unchanged",
      "instances": "reset-and-import" | "reset" | "unchanged",
      "remote":    "reset-and-import" | "reset" | "unchanged"
    },
    "triggers":         "reset-and-import" | "reset" | "unchanged",
    "customVariables":  "reset-and-import" | "reset" | "unchanged",
    "expressionVariables": "reset-and-import" | "reset" | "unchanged",
    "connections":      "reset" | "unchanged",
    "userconfig":       "reset" | "unchanged"
  }
}
```

**Breaking**: `surfaces` now requires three keys. Sending the 4.2
shape against 4.3 fails with
`"Invalid or malformed input provided for importExport.importFull/mutation"`.

companion-deploy.py sends the 4.3 shape (forward-compatible — extra
keys silently ignored by 4.2's Zod parser).

---

## surfaces.outbound.add mutation

Schema source: `companion/lib/Surface/Outbound.ts`.

### 4.2

```jsonc
{
  "type":    "elgato",
  "address": "<ip>",
  "port":    5343,
  "name":    "<display name>"   // optional
}
```

Mutation returns the new outbound entry's nanoid `id`.

### 4.3

```jsonc
{
  "instanceId":   "<surface-instance-nanoid>",
  "connectionId": "<discovered-connection-id>"   // optional
}
```

Returns `{ ok: true, id: "<new-nanoid>" }` or `{ ok: false, error: "..." }`.

**Breaking**: 4.3 adds via instance-and-discovery model. The
`instanceId` is the nanoid of a registered surface plugin instance
(NOT the moduleId like `"elgato-stream-deck"`). Find it from
`/int/export/full` → `surfaceInstances`:

```jsonc
{
  "surfaceInstances": {
    "sFT0_X6W98WuHO9JV6GaA": {
      "moduleInstanceType": "surface",
      "moduleId": "elgato-stream-deck",
      ...
    }
  }
}
```

The key (`sFT0_X6W98WuHO9JV6GaA`) is what `surfaces.outbound.add`
expects as `instanceId`.

After `add` returns the new outbound entry's id, you must
**`surfaces.outbound.saveConfig`** with the actual host/port:

```jsonc
{
  "id":     "<new-id-from-add>",
  "name":   "<display name>",
  "config": { "address": "<ip>", "port": 5343 }   // NOT { host: ... }
}
```

**Breaking sub-detail**: the config key is `address`, NOT `host`.
Sending `host: "..."` is silently accepted by saveConfig but the
plugin then sees an empty address and fails to connect (the wrapper
emits `Setting up 1 remote connections: - <id> ({"address":"","port":5343})`
in the log — a tell-tale sign).

---

## surfaces.groupSetConfigKey mutation

Both 4.2 and 4.3 accept the same shape:

```jsonc
{
  "groupId": "<group-id>",
  "key":     "startup_page_id" | "last_page_id" | "use_last_page" | ...,
  "value":   <varies>
}
```

In 4.3, when a surface has no explicit group ("auto-group" case for
offline or freshly-paired devices), the surface ID itself
(`streamdeck:A00NA53835A5F1`) is accepted as the `groupId`. This is
how companion-deploy.py assigns startup pages without first creating
explicit surface groups.

---

## Page IDs

Both versions: pages have nanoid `id` fields generated at import
time. `groupSetConfigKey` for `startup_page_id` requires the actual
nanoid, NOT the page number.

Look up: `/int/export/full` → `pages.<page_number>.id`.

---

## Surface keys to set per-page

For each surface you want to land on a specific page:

```jsonc
[
  { "key": "startup_page_id", "value": "<page-nanoid>" },
  { "key": "last_page_id",    "value": "<page-nanoid>" },
  { "key": "use_last_page",   "value": false }
]
```

Order matters slightly: set startup before last_page, set
use_last_page=false last so the surface honors the new startup_page.

---

## Cross-references

- companion-deploy.py: `apps/companion/scripts/companion-deploy.py`
- 4.2 source local: `/tmp/companion-42/`
- 4.3 source local: `/tmp/companion-43/`
- Bitfocus releases: https://github.com/bitfocus/companion/releases
- companion-pi installer: https://github.com/bitfocus/companion-pi
- API health: GET `/int/export/full` returns gzipped JSON of full state
