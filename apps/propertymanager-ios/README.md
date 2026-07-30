# PropertyManager iOS

Native SwiftUI iPhone app for RedBud Ranch maintenance tasks.

It talks to the PropertyManager Flask API (`tools/property_manager/api/propertymanager_api.py`) for:

- categories
- active tasks (including part numbers / parts list)
- edit parts + notes/supplies/description (`PATCH /tasks/<id>`)
- add/edit/remove parts list with quantity, vendor, OEM #, buy/supply URL (`PUT /tasks/<id>/parts`)
- mark complete (`POST /tasks/<id>/complete`)

## Requirements

- Mac with **Xcode 16+**
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iPhone on the same Tailscale/LAN as the host running PropertyManager API (`:5062`)
- Apple ID signed into Xcode for automatic signing

## Run on your iPhone

```bash
cd ~/ai/projects/openclaw/apps/propertymanager-ios
xcodegen generate
open PropertyManager.xcodeproj
```

In Xcode:

1. Select the **PropertyManager** scheme.
2. Choose your connected **iPhone**.
3. Set your **Team** under Signing & Capabilities (Personal Team is fine for local installs).
4. Product → Run.

On first launch, open **Settings** and set the API base URL if needed:

```text
http://100.85.36.72:5062
```

Use your Intel Mini Tailscale IP or LAN hostname. Then tap **Test Connection** / **Refresh Tasks**.

## API host

Start the API on the machine that has the PropertyManager Postgres schema:

```bash
cd ~/ai/projects/openclaw
python3 tools/property_manager/api/propertymanager_api.py
```

Default listen address: `0.0.0.0:5062`.

Endpoints used by the app:

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Connectivity check |
| GET | `/categories` | Category list |
| DELETE | `/categories/<id>` | Delete category; if tasks remain, require JSON `reassign_to` (409 otherwise) |
| GET | `/tasks` | Active tasks |
| GET | `/tasks/<id>` | Task detail |
| PATCH | `/tasks/<id>` | Update primary part fields / notes / supplies / description |
| PUT | `/tasks/<id>/parts` | Replace full parts list (name, qty, vendor, OEM #, buy URL, …) |
| POST | `/tasks/<id>/parts` | Append one part |
| POST | `/tasks/<id>/complete` | Mark done + schedule next due |

## App features

- Task list with All / Due / Overdue filters
- Category filter + search
- Due/overdue/critical status from `next_due`, `warning_days`, `critical_days`
- Task detail with instructions, supplies, parts
- Mark Done with optional note

## OpenClaw iOS (companion app)

The separate OpenClaw chat/gateway iPhone app lives at `apps/ios`.

```bash
cd ~/ai/projects/openclaw
pnpm install
./scripts/ios-configure-signing.sh
cd apps/ios
xcodegen generate
open OpenClaw.xcodeproj
```

Then run the **OpenClaw** scheme on your iPhone. Full notes: [`apps/ios/README.md`](../ios/README.md).
