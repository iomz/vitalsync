# Vitalsync

iOS app for syncing selected Apple Health data to Vitalsync receiver endpoints.

## Requirements

- Xcode 16 or newer
- iPhone with Health app data
- Apple Developer team with HealthKit capability enabled for bundle ID

## Configure signing

Edit `Configuration/Signing.xcconfig`:

```xcconfig
PRODUCT_BUNDLE_IDENTIFIER = your.bundle.id
DEVELOPMENT_TEAM = YOURTEAMID
```

Xcode can also set these values in target signing settings.

## Run on iPhone

Connect iPhone, trust Mac, then run:

```sh
./scripts/deploy-iphone.sh
```

Optional overrides:

```sh
TEAM_ID=YOURTEAMID BUNDLE_ID=your.bundle.id DEVICE_NAME="Iori iPhone" ./scripts/deploy-iphone.sh
```

Script builds and installs through Xcode automatic signing. If multiple devices are attached, set `DEVICE_NAME`.

## Run local receiver

The local receiver is stdlib-only Python and stores data in SQLite. For iPhone testing on your LAN, run it from an editable checkout:

```sh
VITALSYNC_ADMIN_TOKEN="$(openssl rand -hex 32)" \
VITALSYNC_PUBLIC_BASE_URL="http://YOUR_MAC_LAN_IP:8790" \
./scripts/run-receiver.sh
```

Or install and run the receiver package directly:

```sh
python -m pip install -e receiver
python -m vitalsync_receiver
```

Direct package runs bind to `127.0.0.1` by default. Set `VITALSYNC_HOST=0.0.0.0` when the receiver must accept LAN traffic.

Docker Compose runs the receiver on port `8790`, binds it to localhost for reverse-proxy use, and persists SQLite data in the `vitalsync-data` volume mounted at `/data`. Create a local env file first:

```sh
cp receiver/.env.example receiver/.env
VITALSYNC_ADMIN_TOKEN="$(openssl rand -hex 32)" >> receiver/.env
docker compose up vitalsync-receiver
```

On iPhone, set Account -> Receiver -> API base URL to a host reachable from the device, not `localhost`:

```text
http://YOUR_MAC_LAN_IP:8790/vitalsync/v1
```

Device registration is closed by default. `POST /devices/register` requires `Authorization: Bearer $VITALSYNC_ADMIN_TOKEN` unless the receiver is started with `--open-registration` or `VITALSYNC_OPEN_REGISTRATION=1`. Admin-only endpoints and consumer token creation also require the admin token.

Create a consumer read token:

```sh
curl -sS -X POST "http://127.0.0.1:8790/vitalsync/v1/consumer-tokens" \
  -H "Authorization: Bearer $VITALSYNC_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"scope":["read:activity","read:sleep","read:vitals","read:body","read:blood_pressure","read:workouts"],"expires_in_seconds":86400}'
```

Fetch records:

```sh
curl -sS "http://127.0.0.1:8790/vitalsync/v1/records?sample_type=step_count" \
  -H "Authorization: Bearer vitalsync_consumer_..."
```

Uploaded and queried timestamps must be valid ISO-8601 values. The receiver normalizes accepted timestamps to UTC before storing them.

WebTransport upload is specified but not implemented in this stdlib receiver; iOS falls back to `POST /batches`.

## Manual Xcode flow

```sh
open Vitalsync.xcodeproj
```

Select `Vitalsync` scheme, choose iPhone destination, verify signing, then Run.

## Source layout

- `Vitalsync/Sources`: SwiftUI app, HealthKit mapping, sync engine, transport, App Intents.
- `Vitalsync/SupportingFiles`: Info.plist and HealthKit entitlement.
- `Configuration`: signing overrides used by Xcode project and deploy script.
- `receiver`: Python SQLite local receiver implementing the HTTP API spec.
- `docs`: Claude-generated architecture and API reference artifacts.
