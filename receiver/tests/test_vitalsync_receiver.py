import json
import sqlite3
import sys
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from vitalsync_receiver.main import API_PREFIX, Config, make_receiver, token_hash


class ReceiverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False)
        self.tmp.close()
        self.receiver = make_receiver(
            Config(
                db_path=self.tmp.name,
                public_base_url="http://127.0.0.1:0",
                admin_token="admin-secret",
                open_registration=True,
            ),
            "127.0.0.1",
            0,
        )
        self.thread = threading.Thread(target=self.receiver.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.receiver.server_address[1]

    def tearDown(self):
        self.receiver.shutdown()
        self.receiver.server_close()
        self.thread.join(timeout=2)

    def request(self, method, path, body=None, headers=None):
        conn = HTTPConnection("127.0.0.1", self.port, timeout=5)
        raw = json.dumps(body).encode() if body is not None else None
        req_headers = {"Content-Type": "application/json"}
        if headers:
            req_headers.update(headers)
        conn.request(method, f"{API_PREFIX}{path}", raw, req_headers)
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, json.loads(data.decode())

    def test_register_upload_fetch(self):
        status, registered = self.request(
            "POST",
            "/devices/register",
            {
                "app": "Vitalsync",
                "device_label": "Test iPhone",
                "platform": "iOS",
                "app_version": "0.1.0",
            },
        )
        self.assertEqual(status, 200)
        device_id = registered["device_id"]
        access = registered["access_token"]

        batch = {
            "schema": "vitalsync.batch.v1",
            "batch_id": "batch_test_1",
            "device_id": device_id,
            "created_at": "2026-06-26T10:12:30+09:00",
            "timezone": "Asia/Tokyo",
            "sequence": 1,
            "records": [
                {
                    "schema": "vitalsync.record.v1",
                    "source": "apple_health",
                    "source_id": "sample_1",
                    "sample_type": "step_count",
                    "source_bundle_id": "com.apple.Health",
                    "source_name": "Health",
                    "start_time": "2026-06-26T00:00:00+09:00",
                    "end_time": "2026-06-26T00:10:00+09:00",
                    "timezone": "Asia/Tokyo",
                    "value": {"quantity": 120},
                    "unit": "count",
                    "metadata": {},
                }
            ],
            "deleted": [],
        }
        status, ack = self.request(
            "POST",
            "/batches",
            batch,
            {
                "Authorization": f"Bearer {access}",
                "Idempotency-Key": "batch_test_1",
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(ack["accepted"], 1)
        self.assertFalse(ack["duplicate"])

        status, duplicate = self.request(
            "POST",
            "/batches",
            batch,
            {
                "Authorization": f"Bearer {access}",
                "Idempotency-Key": "batch_test_1",
            },
        )
        self.assertEqual(status, 200)
        self.assertTrue(duplicate["duplicate"])

        status, consumer = self.request(
            "POST",
            "/consumer-tokens",
            {"scope": ["read:activity"], "expires_in_seconds": 3600},
            {"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(status, 200)

        status, records = self.request(
            "GET",
            "/records?sample_type=step_count&limit=10",
            headers={"Authorization": f"Bearer {consumer['access_token']}"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(records["schema"], "vitalsync.records.v1")
        self.assertEqual(records["records"][0]["schema"], "vitalsync.record.v1")
        self.assertEqual(records["records"][0]["source_id"], "sample_1")

        status, stats = self.request(
            "GET",
            "/admin/stats",
            headers={"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(stats["schema"], "vitalsync.receiver_stats.v1")
        self.assertGreaterEqual(stats["database"]["size_bytes"], 0)
        self.assertEqual(stats["devices"]["total"], 1)
        self.assertEqual(stats["devices"]["active"], 1)
        self.assertEqual(stats["batches"]["total"], 1)
        self.assertEqual(stats["records"]["total"], 1)
        self.assertEqual(stats["records"]["active"], 1)
        self.assertEqual(stats["records"]["deleted"], 0)
        self.assertEqual(stats["records"]["by_sample_type"][0]["sample_type"], "step_count")
        self.assertEqual(stats["records"]["by_sample_type"][0]["active"], 1)

        status, error = self.request(
            "GET",
            "/batches",
            headers={"Authorization": f"Bearer {consumer['access_token']}"},
        )
        self.assertEqual(status, 403)
        self.assertEqual(error["code"], "permission_denied")

    def test_batch_conflict(self):
        status, registered = self.request(
            "POST",
            "/devices/register",
            {
                "app": "Vitalsync",
                "device_label": "Test iPhone",
                "platform": "iOS",
                "app_version": "0.1.0",
            },
        )
        self.assertEqual(status, 200)
        device_id = registered["device_id"]
        headers = {
            "Authorization": f"Bearer {registered['access_token']}",
            "Idempotency-Key": "batch_conflict",
        }
        batch = {
            "schema": "vitalsync.batch.v1",
            "batch_id": "batch_conflict",
            "device_id": device_id,
            "created_at": "2026-06-26T10:12:30+09:00",
            "timezone": "Asia/Tokyo",
            "sequence": 1,
            "records": [],
            "deleted": [],
        }
        self.assertEqual(self.request("POST", "/batches", batch, headers)[0], 200)
        batch["sequence"] = 2
        status, error = self.request("POST", "/batches", batch, headers)
        self.assertEqual(status, 409)
        self.assertEqual(error["code"], "batch_id_conflict")

    def test_pairing_token_registers_device_once_when_registration_closed(self):
        self.receiver.config.open_registration = False
        status, pairing = self.request(
            "POST",
            "/admin/pairing-tokens",
            {
                "schema": "vitalsync.pairing_token_request.v1",
                "client_type": "iphone",
                "scopes": ["write:healthkit"],
                "ttl_seconds": 600,
            },
            {"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(pairing["schema"], "vitalsync.pairing_token.v1")
        self.assertIn("registration_url", pairing)
        self.assertIn("base_url=", pairing["registration_url"])
        self.assertNotIn("token=", pairing["registration_url"])

        status, registered = self.request(
            "POST",
            "/devices/register",
            {
                "schema": "vitalsync.device_registration.v1",
                "pairing_token": pairing["pairing_token"],
                "device_label": "Test iPhone",
                "platform": "iOS",
                "app_version": "0.1.0",
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(registered["scopes"], ["write:healthkit"])

        status, reused = self.request(
            "POST",
            "/devices/register",
            {
                "schema": "vitalsync.device_registration.v1",
                "pairing_token": pairing["pairing_token"],
                "device_label": "Other iPhone",
                "platform": "iOS",
                "app_version": "0.1.0",
            },
        )
        self.assertEqual(status, 401)
        self.assertEqual(reused["code"], "invalid_pairing_token")

        batch = {
            "schema": "vitalsync.batch.v1",
            "batch_id": "batch_pairing",
            "device_id": registered["device_id"],
            "created_at": "2026-06-26T10:12:30+09:00",
            "records": [],
            "deleted": [],
        }
        status, ack = self.request(
            "POST",
            "/batches",
            batch,
            {
                "Authorization": f"Bearer {registered['access_token']}",
                "Idempotency-Key": "batch_pairing",
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(ack["accepted"], 0)

    def test_expired_pairing_token_is_rejected(self):
        self.receiver.config.open_registration = False
        status, pairing = self.request(
            "POST",
            "/admin/pairing-tokens",
            {
                "client_type": "iphone",
                "scopes": ["write:healthkit"],
                "ttl_seconds": 600,
            },
            {"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(status, 200)
        with sqlite3.connect(self.tmp.name) as conn:
            conn.execute(
                "update pairing_tokens set expires_at = ? where token_hash = ?",
                ("2000-01-01T00:00:00Z", token_hash(pairing["pairing_token"])),
            )

        status, error = self.request(
            "POST",
            "/devices/register",
            {
                "pairing_token": pairing["pairing_token"],
                "device_label": "Test iPhone",
                "platform": "iOS",
                "app_version": "0.1.0",
            },
        )
        self.assertEqual(status, 401)
        self.assertEqual(error["code"], "invalid_pairing_token")

    def test_ingest_client_pairing_token_is_read_only(self):
        status, pairing = self.request(
            "POST",
            "/admin/pairing-tokens",
            {
                "client_type": "ingest",
                "scopes": ["read:healthkit"],
                "ttl_seconds": 600,
            },
            {"Authorization": "Bearer admin-secret"},
        )
        self.assertEqual(status, 200)
        status, registered = self.request(
            "POST",
            "/clients/register",
            {
                "schema": "vitalsync.client_registration.v1",
                "pairing_token": pairing["pairing_token"],
                "client_type": "ingest",
                "client_label": "ingest on sazanka",
            },
        )
        self.assertEqual(status, 200)
        self.assertEqual(registered["scopes"], ["read:healthkit"])

        status, batches = self.request(
            "GET",
            "/batches",
            headers={"Authorization": f"Bearer {registered['access_token']}"},
        )
        self.assertEqual(status, 200)
        self.assertEqual(batches["schema"], "vitalsync.batches.v1")

        status, error = self.request(
            "POST",
            "/batches",
            {
                "schema": "vitalsync.batch.v1",
                "batch_id": "batch_read_only",
                "device_id": "dev_fake",
                "created_at": "2026-06-26T10:12:30+09:00",
                "records": [],
                "deleted": [],
            },
            {
                "Authorization": f"Bearer {registered['access_token']}",
                "Idempotency-Key": "batch_read_only",
            },
        )
        self.assertEqual(status, 403)
        self.assertEqual(error["code"], "permission_denied")


if __name__ == "__main__":
    unittest.main()
