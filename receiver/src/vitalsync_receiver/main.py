#!/usr/bin/env python3
"""Vitalsync local receiver.

Stdlib-only HTTP + SQLite implementation of docs/api_reference.html.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import hmac
import json
import logging
import os
import secrets
import sqlite3
import threading
import time
from contextlib import contextmanager
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterator
from urllib.parse import parse_qs, quote, urlparse


API_PREFIX = "/vitalsync/v1"
SCHEMA_BATCH = "vitalsync.batch.v1"
SCHEMA_BATCHES = "vitalsync.batches.v1"
SCHEMA_RECORD = "vitalsync.record.v1"
SCHEMA_RECORDS = "vitalsync.records.v1"
MAX_BATCH_BYTES = 1_048_576
ACCESS_TOKEN_SECONDS = 3600
REFRESH_TOKEN_SECONDS = 60 * 60 * 24 * 365
PAIRING_TOKEN_SECONDS = 600
READ_HEALTHKIT_SCOPE = "read:healthkit"
WRITE_HEALTHKIT_SCOPE = "write:healthkit"

SAMPLE_TYPE_SCOPES = {
    "sleep_analysis": "read:sleep",
    "step_count": "read:activity",
    "daily_step_count": "read:activity",
    "walking_running_distance": "read:activity",
    "flights_climbed": "read:activity",
    "active_energy_burned": "read:activity",
    "basal_energy_burned": "read:activity",
    "exercise_time": "read:activity",
    "stand_time": "read:activity",
    "body_mass": "read:body",
    "body_fat_percentage": "read:body",
    "lean_body_mass": "read:body",
    "height": "read:body",
    "heart_rate": "read:vitals",
    "resting_heart_rate": "read:vitals",
    "heart_rate_variability_sdnn": "read:vitals",
    "respiratory_rate": "read:vitals",
    "oxygen_saturation": "read:vitals",
    "body_temperature": "read:vitals",
    "blood_pressure": "read:blood_pressure",
    "blood_pressure_systolic": "read:blood_pressure",
    "blood_pressure_diastolic": "read:blood_pressure",
    "workout": "read:workouts",
}


logger = logging.getLogger("vitalsync_receiver")


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(value: dt.datetime) -> str:
    return value.isoformat().replace("+00:00", "Z")


def parse_time(value: str | None, *, field: str = "timestamp") -> str | None:
    if not value:
        return None
    return normalize_time(value, field=field)


def normalize_time(value: Any, *, field: str = "timestamp") -> str | None:
    if value is None:
        return None

    raw = str(value).strip()
    if not raw:
        return None

    if len(raw) == 10:
        raw = f"{raw}T00:00:00Z"

    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValueError(f"{field} must be an ISO-8601 timestamp") from exc

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)

    return iso(parsed.astimezone(dt.timezone.utc))


def canonical_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha256_json(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def sqlite_database_size_bytes(db_path: Path) -> int:
    return sum(
        candidate.stat().st_size
        for candidate in (
            db_path,
            db_path.with_name(f"{db_path.name}-wal"),
            db_path.with_name(f"{db_path.name}-shm"),
        )
        if candidate.exists()
    )


def make_id(prefix: str) -> str:
    return f"{prefix}_{secrets.token_urlsafe(18)}"


def read_cursor(value: str | None) -> int:
    if not value:
        return 0
    try:
        decoded = base64.urlsafe_b64decode(value.encode("ascii") + b"===")
        parsed = int(decoded.decode("ascii"))
        return max(parsed, 0)
    except Exception:
        return 0


def make_cursor(offset: int, count: int, limit: int) -> str | None:
    if count < limit:
        return None
    raw = str(offset + count).encode("ascii")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def validate_pairing_request(client_type: str, scopes: list[str]) -> None:
    allowed = {
        "iphone": {WRITE_HEALTHKIT_SCOPE},
        "ingest": {READ_HEALTHKIT_SCOPE},
    }
    if client_type not in allowed:
        raise ValueError("client_type must be iphone or ingest")
    if not scopes:
        raise ValueError("scopes must be a non-empty array")
    if not set(scopes).issubset(allowed[client_type]):
        raise ValueError("scopes are not allowed for client_type")


def int_field(value: Any, default: int, *, field: str) -> int:
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be an integer") from exc


class Config:
    def __init__(
        self,
        db_path: str,
        public_base_url: str,
        admin_token: str | None,
        open_registration: bool,
    ) -> None:
        self.db_path = db_path
        self.public_base_url = public_base_url.rstrip("/")
        self.admin_token = admin_token
        self.open_registration = open_registration


class Store:
    def __init__(self, db_path: str) -> None:
        self.db_path = db_path
        db_parent = Path(db_path).expanduser().parent
        if str(db_parent) not in ("", "."):
            db_parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.init_db()

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA journal_mode = WAL")
        try:
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def init_db(self) -> None:
        with self.connect() as conn:
            conn.executescript(
                """
                create table if not exists healthkit_batches (
                  batch_id text primary key,
                  device_id text not null,
                  created_at text not null,
                  received_at text not null,
                  schema text not null,
                  payload_json text not null,
                  payload_sha256 text not null
                );

                create table if not exists healthkit_records (
                  source text not null,
                  source_id text not null,
                  device_id text not null,
                  sample_type text not null,
                  source_bundle_id text,
                  source_name text,
                  start_time text,
                  end_time text,
                  timezone text,
                  value_json text not null,
                  metadata_json text not null,
                  batch_id text not null,
                  deleted integer not null default 0,
                  updated_at text not null,
                  primary key (source, source_id)
                );

                create table if not exists healthkit_devices (
                  device_id text primary key,
                  device_label text,
                  app_version text,
                  platform text,
                  created_at text,
                  revoked_at text
                );

                create table if not exists healthkit_tokens (
                  token_hash text primary key,
                  device_id text,
                  token_type text not null,
                  scopes_json text not null,
                  expires_at text,
                  revoked_at text
                );

                create table if not exists pairing_tokens (
                  token_hash text primary key,
                  client_type text not null,
                  scopes_json text not null,
                  created_at text not null,
                  expires_at text not null,
                  consumed_at text
                );

                create table if not exists clients (
                  client_id text primary key,
                  client_type text not null,
                  client_label text,
                  created_at text not null,
                  revoked_at text
                );

                create table if not exists client_tokens (
                  token_hash text primary key,
                  client_id text not null,
                  token_type text not null,
                  scopes_json text not null,
                  expires_at text,
                  created_at text not null,
                  revoked_at text
                );

                create index if not exists idx_records_type_time
                  on healthkit_records(sample_type, start_time, end_time);
                create index if not exists idx_batches_received
                  on healthkit_batches(received_at);
                create index if not exists idx_tokens_device
                  on healthkit_tokens(device_id);
                create index if not exists idx_client_tokens_client
                  on client_tokens(client_id);
                """
            )

    def stats(self) -> dict[str, Any]:
        db_path = Path(self.db_path).expanduser()
        db_size_bytes = sqlite_database_size_bytes(db_path)
        with self.connect() as conn:
            device_count = conn.execute(
                "select count(*) as count from healthkit_devices"
            ).fetchone()["count"]
            active_device_count = conn.execute(
                "select count(*) as count from healthkit_devices where revoked_at is null"
            ).fetchone()["count"]
            client_count = conn.execute(
                "select count(*) as count from clients"
            ).fetchone()["count"]
            batch_row = conn.execute(
                """
                select count(*) as count, max(received_at) as latest_received_at
                from healthkit_batches
                """
            ).fetchone()
            record_row = conn.execute(
                """
                select
                  count(*) as total,
                  sum(case when deleted = 0 then 1 else 0 end) as active,
                  sum(case when deleted = 1 then 1 else 0 end) as deleted,
                  max(updated_at) as latest_updated_at
                from healthkit_records
                """
            ).fetchone()
            sample_rows = conn.execute(
                """
                select
                  sample_type,
                  count(*) as total,
                  sum(case when deleted = 0 then 1 else 0 end) as active,
                  sum(case when deleted = 1 then 1 else 0 end) as deleted,
                  max(end_time) as latest_end_time,
                  max(updated_at) as latest_updated_at
                from healthkit_records
                group by sample_type
                order by sample_type
                """
            ).fetchall()
        return {
            "schema": "vitalsync.receiver_stats.v1",
            "server_time": iso(utcnow()),
            "database": {
                "path": str(db_path),
                "size_bytes": db_size_bytes,
            },
            "devices": {
                "total": int(device_count or 0),
                "active": int(active_device_count or 0),
            },
            "clients": {
                "total": int(client_count or 0),
            },
            "batches": {
                "total": int(batch_row["count"] or 0),
                "latest_received_at": batch_row["latest_received_at"],
            },
            "records": {
                "total": int(record_row["total"] or 0),
                "active": int(record_row["active"] or 0),
                "deleted": int(record_row["deleted"] or 0),
                "latest_updated_at": record_row["latest_updated_at"],
                "by_sample_type": [
                    {
                        "sample_type": row["sample_type"],
                        "total": int(row["total"] or 0),
                        "active": int(row["active"] or 0),
                        "deleted": int(row["deleted"] or 0),
                        "latest_end_time": row["latest_end_time"],
                        "latest_updated_at": row["latest_updated_at"],
                    }
                    for row in sample_rows
                ],
            },
        }

    def insert_token(
        self,
        conn: sqlite3.Connection,
        token: str,
        device_id: str | None,
        token_type: str,
        scopes: list[str],
        expires_at: dt.datetime | None,
    ) -> None:
        conn.execute(
            """
            insert into healthkit_tokens
              (token_hash, device_id, token_type, scopes_json, expires_at, revoked_at)
            values (?, ?, ?, ?, ?, null)
            """,
            (
                token_hash(token),
                device_id,
                token_type,
                json.dumps(scopes),
                iso(expires_at) if expires_at else None,
            ),
        )

    def insert_client_token(
        self,
        conn: sqlite3.Connection,
        token: str,
        client_id: str,
        token_type: str,
        scopes: list[str],
        expires_at: dt.datetime | None,
    ) -> None:
        conn.execute(
            """
            insert into client_tokens
              (token_hash, client_id, token_type, scopes_json, expires_at, created_at, revoked_at)
            values (?, ?, ?, ?, ?, ?, null)
            """,
            (
                token_hash(token),
                client_id,
                token_type,
                json.dumps(scopes),
                iso(expires_at) if expires_at else None,
                iso(utcnow()),
            ),
        )

    def create_pairing_token(
        self, client_type: str, scopes: list[str], ttl_seconds: int
    ) -> dict[str, Any]:
        token = make_id("vitalsync_pair")
        now = utcnow()
        expires = now + dt.timedelta(seconds=ttl_seconds)
        with self.lock, self.connect() as conn:
            conn.execute(
                """
                insert into pairing_tokens
                  (token_hash, client_type, scopes_json, created_at, expires_at, consumed_at)
                values (?, ?, ?, ?, ?, null)
                """,
                (
                    token_hash(token),
                    client_type,
                    json.dumps(scopes),
                    iso(now),
                    iso(expires),
                ),
            )
        return {
            "pairing_token": token,
            "client_type": client_type,
            "scopes": scopes,
            "expires_at": iso(expires),
        }

    def consume_pairing_token(
        self, conn: sqlite3.Connection, token: str, client_type: str
    ) -> list[str] | None:
        row = conn.execute(
            """
            select client_type, scopes_json, expires_at, consumed_at
            from pairing_tokens
            where token_hash = ?
            """,
            (token_hash(token),),
        ).fetchone()
        if not row or row["client_type"] != client_type or row["consumed_at"]:
            return None
        expires = dt.datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
        if expires <= utcnow():
            return None
        now = iso(utcnow())
        cur = conn.execute(
            """
            update pairing_tokens
            set consumed_at = ?
            where token_hash = ? and consumed_at is null and expires_at > ?
            """,
            (now, token_hash(token), now),
        )
        if cur.rowcount != 1:
            return None
        return json.loads(row["scopes_json"])

    def validate_token(self, token: str, config: Config) -> dict[str, Any] | None:
        if config.admin_token and hmac.compare_digest(token, config.admin_token):
            return {
                "device_id": None,
                "client_id": None,
                "token_type": "admin",
                "scopes": ["admin:tokens", "admin:devices"],
            }
        with self.connect() as conn:
            row = conn.execute(
                """
                select t.*, d.revoked_at as device_revoked_at
                from healthkit_tokens t
                left join healthkit_devices d on d.device_id = t.device_id
                where t.token_hash = ?
                """,
                (token_hash(token),),
            ).fetchone()
        if not row or row["revoked_at"] or row["device_revoked_at"]:
            return self.validate_client_token(token)
        if row["expires_at"]:
            expires = dt.datetime.fromisoformat(
                row["expires_at"].replace("Z", "+00:00")
            )
            if expires <= utcnow():
                return self.validate_client_token(token)
        return {
            "device_id": row["device_id"],
            "client_id": None,
            "token_type": row["token_type"],
            "scopes": json.loads(row["scopes_json"]),
        }

    def validate_client_token(self, token: str) -> dict[str, Any] | None:
        with self.connect() as conn:
            row = conn.execute(
                """
                select t.*, c.revoked_at as client_revoked_at
                from client_tokens t
                join clients c on c.client_id = t.client_id
                where t.token_hash = ?
                """,
                (token_hash(token),),
            ).fetchone()
        if not row or row["revoked_at"] or row["client_revoked_at"]:
            return None
        if row["expires_at"]:
            expires = dt.datetime.fromisoformat(
                row["expires_at"].replace("Z", "+00:00")
            )
            if expires <= utcnow():
                return None
        return {
            "device_id": None,
            "client_id": row["client_id"],
            "token_type": row["token_type"],
            "scopes": json.loads(row["scopes_json"]),
        }

    def revoke_device(self, device_id: str) -> bool:
        with self.lock, self.connect() as conn:
            now = iso(utcnow())
            cur = conn.execute(
                "update healthkit_devices set revoked_at = ? where device_id = ? and revoked_at is null",
                (now, device_id),
            )
            conn.execute(
                "update healthkit_tokens set revoked_at = ? where device_id = ? and revoked_at is null",
                (now, device_id),
            )
            return cur.rowcount > 0

    def purge_device(self, device_id: str) -> dict[str, int]:
        with self.lock, self.connect() as conn:
            records = conn.execute(
                "delete from healthkit_records where device_id = ?", (device_id,)
            ).rowcount
            batches = conn.execute(
                "delete from healthkit_batches where device_id = ?", (device_id,)
            ).rowcount
            tokens = conn.execute(
                "delete from healthkit_tokens where device_id = ?", (device_id,)
            ).rowcount
            devices = conn.execute(
                "delete from healthkit_devices where device_id = ?", (device_id,)
            ).rowcount
            return {
                "records": records,
                "batches": batches,
                "tokens": tokens,
                "devices": devices,
            }

    def purge_sample_type(self, sample_type: str) -> int:
        with self.lock, self.connect() as conn:
            return conn.execute(
                "delete from healthkit_records where sample_type = ?", (sample_type,)
            ).rowcount


class ResponseSent(Exception):
    pass


class VitalsyncHandler(BaseHTTPRequestHandler):
    server_version = "Vitalsync/0.2"

    @property
    def store(self) -> Store:
        return self.server.store  # type: ignore[attr-defined]

    @property
    def config(self) -> Config:
        return self.server.config  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: Any) -> None:
        if os.environ.get("VITALSYNC_QUIET") == "1":
            return
        super().log_message(format, *args)

    def do_GET(self) -> None:
        self.route("GET")

    def do_POST(self) -> None:
        self.route("POST")

    def route(self, method: str) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)
        if not path.startswith(API_PREFIX):
            self.error_json(HTTPStatus.NOT_FOUND, "not_found", "unknown endpoint")
            return
        rel = path[len(API_PREFIX) :]
        try:
            if method == "POST" and rel == "/devices/register":
                self.register_device()
            elif method == "POST" and rel == "/clients/register":
                self.register_client()
            elif method == "POST" and rel == "/admin/pairing-tokens":
                self.create_pairing_token()
            elif method == "POST" and rel == "/devices/revoke":
                self.app_revoke_device()
            elif method == "POST" and rel == "/tokens/refresh":
                self.refresh_token()
            elif method == "POST" and rel == "/batches":
                self.upload_batch()
            elif method == "POST" and rel == "/consumer-tokens":
                self.create_consumer_token()
            elif method == "GET" and rel == "/admin/stats":
                self.admin_stats()
            elif method == "GET" and rel == "/records":
                self.fetch_records(qs)
            elif method == "GET" and rel == "/batches":
                self.fetch_batches(qs)
            elif (
                method == "POST"
                and rel.startswith("/devices/")
                and rel.endswith("/revoke")
            ):
                self.admin_revoke_device(rel.split("/")[2])
            elif (
                method == "POST"
                and rel.startswith("/devices/")
                and rel.endswith("/purge")
            ):
                self.admin_purge_device(rel.split("/")[2])
            elif method == "POST" and rel == "/purge":
                self.admin_purge_sample_type(qs)
            elif method == "GET" and rel == "/health":
                self.write_json({"ok": True, "server_time": iso(utcnow())})
            else:
                self.error_json(HTTPStatus.NOT_FOUND, "not_found", "unknown endpoint")
        except ResponseSent:
            return
        except ValueError as exc:
            self.error_json(HTTPStatus.BAD_REQUEST, "bad_request", str(exc))
        except sqlite3.IntegrityError:
            logger.exception("database integrity error")
            self.error_json(
                HTTPStatus.CONFLICT,
                "conflict",
                "database constraint conflict",
            )
        except Exception:
            logger.exception("unhandled request error")
            self.error_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                "server_error",
                "internal server error",
                retryable=True,
            )

    def read_json(self, max_bytes: int = MAX_BATCH_BYTES + 4096) -> Any:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            raise ValueError("missing JSON body")
        if length > max_bytes:
            raise ValueError("request body too large")
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid JSON: {exc.msg}") from exc

    def bearer_token(self) -> str | None:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return None
        return auth.removeprefix("Bearer ").strip()

    def require_auth(self, *scopes: str) -> dict[str, Any] | None:
        token = self.bearer_token()
        if not token:
            self.error_json(
                HTTPStatus.UNAUTHORIZED,
                "missing_token",
                "Authorization Bearer token required",
            )
            return None
        principal = self.store.validate_token(token, self.config)
        if not principal:
            self.error_json(
                HTTPStatus.UNAUTHORIZED,
                "token_expired",
                "token missing, expired, or revoked",
                retryable=True,
            )
            return None
        principal_scopes = set(principal["scopes"])
        if scopes and not set(scopes).issubset(principal_scopes):
            self.error_json(
                HTTPStatus.FORBIDDEN, "permission_denied", "token scope is insufficient"
            )
            return None
        return principal

    def require_any_scope(self, scopes: list[str]) -> dict[str, Any] | None:
        token = self.bearer_token()
        if not token:
            self.error_json(
                HTTPStatus.UNAUTHORIZED,
                "missing_token",
                "Authorization Bearer token required",
            )
            return None
        principal = self.store.validate_token(token, self.config)
        if not principal:
            self.error_json(
                HTTPStatus.UNAUTHORIZED,
                "token_expired",
                "token missing, expired, or revoked",
                retryable=True,
            )
            return None
        if not set(principal["scopes"]).intersection(scopes):
            self.error_json(
                HTTPStatus.FORBIDDEN, "permission_denied", "token scope is insufficient"
            )
            return None
        return principal

    def create_pairing_token(self) -> None:
        if not self.require_auth("admin:tokens"):
            return
        body = self.read_json()
        client_type = str(body.get("client_type") or "").strip()
        raw_scopes = body.get("scopes")
        if not isinstance(raw_scopes, list):
            raise ValueError("scopes must be a non-empty array")
        scopes = [str(scope) for scope in raw_scopes]
        validate_pairing_request(client_type, scopes)
        ttl = int_field(
            body.get("ttl_seconds"), PAIRING_TOKEN_SECONDS, field="ttl_seconds"
        )
        ttl = max(60, min(ttl, 3600))
        created = self.store.create_pairing_token(client_type, scopes, ttl)
        registration_url = (
            "vitalsync://register?"
            f"base_url={quote(self.config.public_base_url, safe='')}"
        )
        self.write_json(
            {
                "schema": "vitalsync.pairing_token.v1",
                **created,
                "registration_url": registration_url,
            }
        )

    def register_device(self) -> None:
        body = self.read_json()
        pairing_token = str(body.get("pairing_token") or "").strip()
        scopes = [WRITE_HEALTHKIT_SCOPE]
        consume_pairing = bool(pairing_token)
        if not self.config.open_registration and not pairing_token:
            if not self.require_auth("admin:devices"):
                return
        label = str(body.get("device_label") or "").strip()
        app_version = str(body.get("app_version") or "").strip()
        platform = str(body.get("platform") or "").strip()
        if not label or not app_version or not platform:
            raise ValueError("device_label, platform, and app_version are required")
        device_id = make_id("dev")
        refresh = make_id("vitalsync_refresh")
        access = make_id("vitalsync_access")
        access_expires = utcnow() + dt.timedelta(seconds=ACCESS_TOKEN_SECONDS)
        refresh_expires = utcnow() + dt.timedelta(seconds=REFRESH_TOKEN_SECONDS)
        with self.store.lock, self.store.connect() as conn:
            if consume_pairing:
                consumed_scopes = self.store.consume_pairing_token(
                    conn, pairing_token, "iphone"
                )
                if not consumed_scopes or WRITE_HEALTHKIT_SCOPE not in consumed_scopes:
                    self.error_json(
                        HTTPStatus.UNAUTHORIZED,
                        "invalid_pairing_token",
                        "pairing token missing, expired, consumed, or invalid",
                        retryable=True,
                    )
                    return
                scopes = consumed_scopes
            conn.execute(
                """
                insert into healthkit_devices
                  (device_id, device_label, app_version, platform, created_at, revoked_at)
                values (?, ?, ?, ?, ?, null)
                """,
                (device_id, label, app_version, platform, iso(utcnow())),
            )
            self.store.insert_token(
                conn, refresh, device_id, "refresh", scopes, refresh_expires
            )
            self.store.insert_token(
                conn, access, device_id, "access", scopes, access_expires
            )
        self.write_json(
            {
                "device_id": device_id,
                "refresh_token": refresh,
                "access_token": access,
                "scopes": scopes,
                "expires_at": iso(access_expires),
            }
        )

    def register_client(self) -> None:
        body = self.read_json()
        pairing_token = str(body.get("pairing_token") or "").strip()
        client_type = str(body.get("client_type") or "").strip()
        client_label = str(body.get("client_label") or "").strip() or None
        if not pairing_token or not client_type:
            raise ValueError("pairing_token and client_type are required")
        client_id = make_id("client")
        refresh = make_id("vitalsync_refresh")
        access = make_id("vitalsync_access")
        access_expires = utcnow() + dt.timedelta(seconds=ACCESS_TOKEN_SECONDS)
        refresh_expires = utcnow() + dt.timedelta(seconds=REFRESH_TOKEN_SECONDS)
        with self.store.lock, self.store.connect() as conn:
            scopes = self.store.consume_pairing_token(conn, pairing_token, client_type)
            if not scopes or READ_HEALTHKIT_SCOPE not in scopes:
                self.error_json(
                    HTTPStatus.UNAUTHORIZED,
                    "invalid_pairing_token",
                    "pairing token missing, expired, consumed, or invalid",
                    retryable=True,
                )
                return
            validate_pairing_request(client_type, scopes)
            conn.execute(
                """
                insert into clients
                  (client_id, client_type, client_label, created_at, revoked_at)
                values (?, ?, ?, ?, null)
                """,
                (client_id, client_type, client_label, iso(utcnow())),
            )
            self.store.insert_client_token(
                conn, refresh, client_id, "refresh", scopes, refresh_expires
            )
            self.store.insert_client_token(
                conn, access, client_id, "access", scopes, access_expires
            )
        self.write_json(
            {
                "client_id": client_id,
                "client_type": client_type,
                "refresh_token": refresh,
                "access_token": access,
                "scopes": scopes,
                "expires_at": iso(access_expires),
            }
        )

    def app_revoke_device(self) -> None:
        body = self.read_json()
        principal = self.require_auth(WRITE_HEALTHKIT_SCOPE)
        if not principal:
            return
        device_id = str(body.get("device_id") or "")
        if not device_id:
            raise ValueError("device_id is required")
        if principal["device_id"] != device_id:
            self.error_json(
                HTTPStatus.FORBIDDEN,
                "permission_denied",
                "token cannot revoke another device",
            )
            return
        self.write_json(
            {"revoked": self.store.revoke_device(device_id), "device_id": device_id}
        )

    def refresh_token(self) -> None:
        body = self.read_json()
        refresh = str(body.get("refresh_token") or "")
        device_id = str(body.get("device_id") or "")
        client_id = str(body.get("client_id") or "")
        if not refresh or not (device_id or client_id):
            raise ValueError("refresh_token and device_id or client_id are required")
        principal = self.store.validate_token(refresh, self.config)
        if (
            not principal
            or principal["token_type"] != "refresh"
            or (device_id and principal["device_id"] != device_id)
            or (client_id and principal["client_id"] != client_id)
        ):
            self.error_json(
                HTTPStatus.UNAUTHORIZED,
                "token_expired",
                "refresh token missing, expired, or revoked",
                retryable=True,
            )
            return
        access = make_id("vitalsync_access")
        expires = utcnow() + dt.timedelta(seconds=ACCESS_TOKEN_SECONDS)
        with self.store.lock, self.store.connect() as conn:
            if client_id:
                self.store.insert_client_token(
                    conn, access, client_id, "access", principal["scopes"], expires
                )
            else:
                self.store.insert_token(
                    conn, access, device_id, "access", principal["scopes"], expires
                )
        self.write_json({"access_token": access, "expires_at": iso(expires)})

    def upload_batch(self) -> None:
        principal = self.require_auth(WRITE_HEALTHKIT_SCOPE)
        if not principal:
            return
        started = time.perf_counter()
        body = self.read_json(MAX_BATCH_BYTES)
        if not isinstance(body, dict):
            raise ValueError("JSON body must be an object")
        read_ms = (time.perf_counter() - started) * 1000
        records = body.get("records") or []
        deleted = body.get("deleted") or []
        batch_id = str(body.get("batch_id") or "")
        store_started = time.perf_counter()
        ack = self.store_batch(body, principal["device_id"])
        store_ms = (time.perf_counter() - store_started) * 1000
        total_ms = (time.perf_counter() - started) * 1000
        logger.info(
            "batch_upload batch_id=%s device_id=%s records=%d deleted=%d duplicate=%s read_ms=%.1f store_ms=%.1f total_ms=%.1f",
            batch_id,
            principal["device_id"],
            len(records) if isinstance(records, list) else 0,
            len(deleted) if isinstance(deleted, list) else 0,
            ack.get("duplicate"),
            read_ms,
            store_ms,
            total_ms,
        )
        self.write_json(ack)

    def store_batch(self, body: dict[str, Any], auth_device_id: str) -> dict[str, Any]:
        required = [
            "schema",
            "batch_id",
            "device_id",
            "created_at",
            "records",
            "deleted",
        ]
        missing = [key for key in required if key not in body]
        if missing:
            raise ValueError(f"missing required fields: {', '.join(missing)}")
        if body["schema"] != SCHEMA_BATCH:
            self.error_json(
                HTTPStatus.BAD_REQUEST,
                "unsupported_schema",
                f"schema {body['schema']} is not supported",
            )
            raise ResponseSent()
        batch_id = str(body["batch_id"])
        idempotency_key = self.headers.get("Idempotency-Key")
        if idempotency_key != batch_id:
            raise ValueError("Idempotency-Key header must equal batch_id")
        device_id = str(body["device_id"])
        if auth_device_id != device_id:
            self.error_json(
                HTTPStatus.FORBIDDEN,
                "permission_denied",
                "device_id does not match token",
            )
            raise ResponseSent()
        records = body.get("records") or []
        deleted = body.get("deleted") or []
        if not isinstance(records, list) or not isinstance(deleted, list):
            raise ValueError("records and deleted must be arrays")
        payload_hash = sha256_json(body)
        payload_json = canonical_json(body)
        with self.store.lock, self.store.connect() as conn:
            existing = conn.execute(
                "select payload_sha256 from healthkit_batches where batch_id = ?",
                (batch_id,),
            ).fetchone()
            if existing:
                if existing["payload_sha256"] != payload_hash:
                    self.error_json(
                        HTTPStatus.CONFLICT,
                        "batch_id_conflict",
                        "batch_id already exists with different payload",
                    )
                    raise ResponseSent()
                return {
                    "batch_id": batch_id,
                    "accepted": len(records),
                    "deleted": len(deleted),
                    "duplicate": True,
                }
            conn.execute(
                """
                insert into healthkit_batches
                  (batch_id, device_id, created_at, received_at, schema, payload_json, payload_sha256)
                values (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    batch_id,
                    device_id,
                    normalize_time(body["created_at"]) or str(body["created_at"]),
                    iso(utcnow()),
                    str(body["schema"]),
                    payload_json,
                    payload_hash,
                ),
            )
            self.index_records(conn, device_id, batch_id, records, deleted)
        return {
            "batch_id": batch_id,
            "accepted": len(records),
            "deleted": len(deleted),
            "duplicate": False,
        }

    def index_records(
        self,
        conn: sqlite3.Connection,
        device_id: str,
        batch_id: str,
        records: list[dict[str, Any]],
        deleted: list[dict[str, Any]],
    ) -> None:
        now = iso(utcnow())
        for record in records:
            source = str(record.get("source") or "")
            source_id = str(record.get("source_id") or "")
            sample_type = str(record.get("sample_type") or "")
            if not source or not source_id or not sample_type:
                raise ValueError(
                    "record source, source_id, and sample_type are required"
                )
            conn.execute(
                """
                insert into healthkit_records (
                  source, source_id, device_id, sample_type, source_bundle_id, source_name,
                  start_time, end_time, timezone, value_json, metadata_json, batch_id, deleted, updated_at
                ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                on conflict(source, source_id) do update set
                  device_id = excluded.device_id,
                  sample_type = excluded.sample_type,
                  source_bundle_id = excluded.source_bundle_id,
                  source_name = excluded.source_name,
                  start_time = excluded.start_time,
                  end_time = excluded.end_time,
                  timezone = excluded.timezone,
                  value_json = excluded.value_json,
                  metadata_json = excluded.metadata_json,
                  batch_id = excluded.batch_id,
                  deleted = 0,
                  updated_at = excluded.updated_at
                """,
                (
                    source,
                    source_id,
                    device_id,
                    sample_type,
                    record.get("source_bundle_id"),
                    record.get("source_name"),
                    normalize_time(record.get("start_time"), field="record.start_time"),
                    normalize_time(record.get("end_time"), field="record.end_time"),
                    record.get("timezone"),
                    canonical_json(record.get("value") or {}),
                    canonical_json(record.get("metadata") or {}),
                    batch_id,
                    now,
                ),
            )
        for tombstone in deleted:
            source = str(tombstone.get("source") or "")
            source_id = str(tombstone.get("source_id") or "")
            sample_type = str(tombstone.get("sample_type") or "")
            if not source or not source_id or not sample_type:
                raise ValueError(
                    "tombstone source, source_id, and sample_type are required"
                )
            conn.execute(
                """
                insert into healthkit_records (
                  source, source_id, device_id, sample_type, value_json, metadata_json,
                  batch_id, deleted, updated_at
                ) values (?, ?, ?, ?, '{}', '{}', ?, 1, ?)
                on conflict(source, source_id) do update set
                  deleted = 1,
                  sample_type = excluded.sample_type,
                  batch_id = excluded.batch_id,
                  updated_at = excluded.updated_at
                """,
                (source, source_id, device_id, sample_type, batch_id, now),
            )

    def create_consumer_token(self) -> None:
        if not self.require_auth("admin:tokens"):
            return
        body = self.read_json()
        scopes = body.get("scope")
        if not isinstance(scopes, list) or not scopes:
            raise ValueError("scope must be a non-empty array")
        scopes = [str(scope) for scope in scopes]
        allowed = set(SAMPLE_TYPE_SCOPES.values())
        allowed.add(READ_HEALTHKIT_SCOPE)
        if not set(scopes).issubset(allowed):
            raise ValueError("scope contains unsupported read scope")
        ttl = int(body.get("expires_in_seconds") or ACCESS_TOKEN_SECONDS)
        expires = utcnow() + dt.timedelta(
            seconds=max(60, min(ttl, REFRESH_TOKEN_SECONDS))
        )
        token = make_id("vitalsync_consumer")
        with self.store.lock, self.store.connect() as conn:
            self.store.insert_token(conn, token, None, "consumer", scopes, expires)
        self.write_json({"access_token": token, "expires_at": iso(expires)})

    def fetch_records(self, qs: dict[str, list[str]]) -> None:
        sample_type = self.query_one(qs, "sample_type")
        if not sample_type:
            raise ValueError("sample_type is required")
        required_scope = SAMPLE_TYPE_SCOPES.get(sample_type)
        if not required_scope:
            raise ValueError("unsupported sample_type")
        if not self.require_any_scope([required_scope, READ_HEALTHKIT_SCOPE]):
            return
        limit = min(int(self.query_one(qs, "limit") or "500"), 1000)
        offset = read_cursor(self.query_one(qs, "cursor"))
        start = parse_time(self.query_one(qs, "start"), field="start")
        end = parse_time(self.query_one(qs, "end"), field="end")
        clauses = ["sample_type = ?", "deleted = 0"]
        params: list[Any] = [sample_type]
        if start:
            clauses.append("end_time >= ?")
            params.append(start)
        if end:
            clauses.append("start_time <= ?")
            params.append(end)
        params.extend([limit, offset])
        with self.store.connect() as conn:
            rows = conn.execute(
                f"""
                select * from healthkit_records
                where {' and '.join(clauses)}
                order by start_time, source, source_id
                limit ? offset ?
                """,
                params,
            ).fetchall()
        records = [self.row_to_record(row) for row in rows]
        self.write_json(
            {
                "schema": SCHEMA_RECORDS,
                "records": records,
                "next_cursor": make_cursor(offset, len(records), limit),
            }
        )

    def row_to_record(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "schema": SCHEMA_RECORD,
            "source": row["source"],
            "source_id": row["source_id"],
            "sample_type": row["sample_type"],
            "source_bundle_id": row["source_bundle_id"],
            "source_name": row["source_name"],
            "start_time": row["start_time"],
            "end_time": row["end_time"],
            "timezone": row["timezone"],
            "value": json.loads(row["value_json"]),
            "unit": None,
            "metadata": json.loads(row["metadata_json"]),
        }

    def fetch_batches(self, qs: dict[str, list[str]]) -> None:
        if not self.require_auth(READ_HEALTHKIT_SCOPE):
            return
        limit = min(int(self.query_one(qs, "limit") or "500"), 1000)
        offset = read_cursor(self.query_one(qs, "cursor"))
        clauses: list[str] = []
        params: list[Any] = []
        since = parse_time(self.query_one(qs, "since"), field="since")
        device_id = self.query_one(qs, "device_id")
        if since:
            clauses.append("received_at > ?")
            params.append(since)
        if device_id:
            clauses.append("device_id = ?")
            params.append(device_id)
        where = f"where {' and '.join(clauses)}" if clauses else ""
        params.extend([limit, offset])
        with self.store.connect() as conn:
            rows = conn.execute(
                f"""
                select payload_json from healthkit_batches
                {where}
                order by received_at, batch_id
                limit ? offset ?
                """,
                params,
            ).fetchall()
        batches = [json.loads(row["payload_json"]) for row in rows]
        self.write_json(
            {
                "schema": SCHEMA_BATCHES,
                "batches": batches,
                "next_cursor": make_cursor(offset, len(batches), limit),
            }
        )

    def admin_stats(self) -> None:
        if not self.require_auth("admin:devices"):
            return
        self.write_json(self.store.stats())

    def admin_revoke_device(self, device_id: str) -> None:
        if not self.require_auth("admin:devices"):
            return
        self.write_json(
            {"revoked": self.store.revoke_device(device_id), "device_id": device_id}
        )

    def admin_purge_device(self, device_id: str) -> None:
        if not self.require_auth("admin:devices"):
            return
        result = self.store.purge_device(device_id)
        self.write_json({"purged": True, "device_id": device_id, **result})

    def admin_purge_sample_type(self, qs: dict[str, list[str]]) -> None:
        if not self.require_auth("admin:devices"):
            return
        sample_type = self.query_one(qs, "sample_type")
        if not sample_type:
            raise ValueError("sample_type is required")
        self.write_json(
            {
                "purged": True,
                "sample_type": sample_type,
                "records": self.store.purge_sample_type(sample_type),
            }
        )

    def query_one(self, qs: dict[str, list[str]], key: str) -> str | None:
        values = qs.get(key)
        return values[0] if values else None

    def write_json(self, payload: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode(
            "utf-8"
        )
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def error_json(
        self,
        status: HTTPStatus,
        code: str,
        message: str,
        retryable: bool = False,
    ) -> None:
        self.write_json(
            {"type": "error", "code": code, "message": message, "retryable": retryable},
            status,
        )


class VitalsyncReceiver(ThreadingHTTPServer):
    def __init__(self, addr: tuple[str, int], store: Store, config: Config) -> None:
        super().__init__(addr, VitalsyncHandler)
        self.store = store
        self.config = config


def make_receiver(config: Config, host: str, port: int) -> VitalsyncReceiver:
    return VitalsyncReceiver((host, port), Store(config.db_path), config)


def main() -> None:
    parser = argparse.ArgumentParser(description="Vitalsync local receiver")
    parser.add_argument("--host", default=os.environ.get("VITALSYNC_HOST", "127.0.0.1"))
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("VITALSYNC_PORT", "8790"))
    )
    parser.add_argument(
        "--db", default=os.environ.get("VITALSYNC_DB", "vitalsync.sqlite3")
    )
    parser.add_argument(
        "--public-base-url",
        default=os.environ.get("VITALSYNC_PUBLIC_BASE_URL", "http://127.0.0.1:8790"),
    )
    parser.add_argument(
        "--admin-token", default=os.environ.get("VITALSYNC_ADMIN_TOKEN")
    )
    parser.add_argument(
        "--open-registration",
        action="store_true",
        default=os.environ.get("VITALSYNC_OPEN_REGISTRATION") == "1",
        help="Do not require admin token for /devices/register",
    )
    args = parser.parse_args()
    config = Config(
        db_path=args.db,
        public_base_url=args.public_base_url,
        admin_token=args.admin_token,
        open_registration=args.open_registration,
    )
    logging.basicConfig(level=logging.INFO)
    httpd = make_receiver(config, args.host, args.port)
    print(f"Vitalsync receiver listening on http://{args.host}:{args.port}{API_PREFIX}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
