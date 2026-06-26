import json
import sys
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from vitalsync_receiver.main import API_PREFIX, Config, make_receiver


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


if __name__ == "__main__":
    unittest.main()
