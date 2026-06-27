# Vitalsync

[![CI](https://github.com/iomz/vitalsync/actions/workflows/ci.yml/badge.svg)](https://github.com/iomz/vitalsync/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

iOS app for syncing selected Apple Health data to Vitalsync receiver endpoints.

Vitalsync is a personal project. It is not a medical device and is not intended for diagnosis, treatment, emergency use, or clinical monitoring.

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
TEAM_ID=YOURTEAMID BUNDLE_ID=your.bundle.id DEVICE_NAME="My iPhone" ./scripts/deploy-iphone.sh
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

Docker Compose runs the receiver on port `8790`, binds it to localhost for reverse-proxy use, and persists SQLite data in the `vitalsync-data` Docker volume mounted at `/data`. Create a local env file first:

```sh
cp receiver/.env.example receiver/.env
VITALSYNC_ADMIN_TOKEN="$(openssl rand -hex 32)" >> receiver/.env
docker compose up vitalsync-receiver
```

On iPhone, set Account -> Receiver -> API base URL to a host reachable from the device, not `localhost`:

```text
http://YOUR_MAC_LAN_IP:8790/vitalsync/v1
```

Device registration is closed by default. Normal iPhone registration uses an admin-issued, short-lived, one-time pairing token. Open registration is only enabled when the receiver is started with `--open-registration` or `VITALSYNC_OPEN_REGISTRATION=1`; do not enable it on an internet-exposed receiver.

The admin token is the receiver-owner/root secret. Keep it on the receiver operator machine for maintenance operations, issuing one-time pairing tokens, and creating read-only consumer tokens. Do not store the admin token in the iOS app, README examples, screenshots, logs, or normal read-only clients.

Create a short-lived iPhone pairing token:

```sh
curl -sS -X POST "http://127.0.0.1:8790/vitalsync/v1/admin/pairing-tokens" \
  -H "Authorization: Bearer $VITALSYNC_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"schema":"vitalsync.pairing_token_request.v1","client_type":"iphone","scopes":["write:healthkit"],"ttl_seconds":600}'
```

Register the iPhone with the returned one-time `pairing_token`:

```sh
curl -sS -X POST "http://127.0.0.1:8790/vitalsync/v1/devices/register" \
  -H "Content-Type: application/json" \
  -d '{"schema":"vitalsync.device_registration.v1","pairing_token":"<PAIRING_TOKEN>","device_label":"My iPhone","platform":"iOS","app_version":"0.1.0"}'
```

In the iOS app, paste the raw `pairing_token` into Account -> Device -> Pairing token. If you open the returned `vitalsync://register?...` URL on iPhone, the app fills the receiver URL and normalizes `base_url=https://receiver.example.com` to `https://receiver.example.com/vitalsync/v1`.

Successful registration consumes the pairing token and returns normal refresh/access tokens with `write:healthkit`. Pairing tokens are stored hashed in SQLite, expire after their TTL, and cannot be reused. Set `VITALSYNC_PUBLIC_BASE_URL=https://receiver.example.com` to make generated endpoint URLs use `https://receiver.example.com/vitalsync/v1/...`; pairing responses also include a future-facing `vitalsync://register?...` URL.

The minimal scope model is:

```text
write:healthkit  iPhone device upload access
read:healthkit   read-only API consumer access
```

Future `ingest` registration uses a read-only client identity rather than a fake HealthKit device:

```sh
curl -sS -X POST "http://127.0.0.1:8790/vitalsync/v1/admin/pairing-tokens" \
  -H "Authorization: Bearer $VITALSYNC_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"schema":"vitalsync.pairing_token_request.v1","client_type":"ingest","scopes":["read:healthkit"],"ttl_seconds":600}'

curl -sS -X POST "http://127.0.0.1:8790/vitalsync/v1/clients/register" \
  -H "Content-Type: application/json" \
  -d '{"schema":"vitalsync.client_registration.v1","pairing_token":"<PAIRING_TOKEN>","client_type":"ingest","client_label":"ingest on receiver.example.com"}'
```

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
  -H "Authorization: Bearer <READ_TOKEN>"
```

Uploaded and queried timestamps must be valid ISO-8601 values. The receiver normalizes accepted timestamps to UTC before storing them.

WebTransport upload is specified but not implemented in this stdlib receiver; iOS falls back to `POST /batches`.

### Revoke vs purge

`revoke` disables a device and all of its tokens while preserving historical data. Use this when a real device should no longer be allowed to sync, but its previously submitted data should remain. Client revocation should follow the same model when it is exposed.

`purge` permanently deletes a device registration and its associated tokens. It is intended for development cleanup, failed registration attempts, and removing test identities.

Current device purge also deletes associated HealthKit records and batches for that device. Sample-type purge deletes matching HealthKit records. Client purge is not currently exposed.

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
