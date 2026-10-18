import io
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import worker


class WorkerProtocolTest(unittest.TestCase):
    def run_worker(self, payload):
        output = io.StringIO()
        with patch("sys.stdin", io.StringIO(json.dumps(payload))), patch("sys.stdout", output):
            self.assertEqual(worker.main(), 0)
        return json.loads(output.getvalue())

    def test_malformed_request_does_not_echo_secrets(self):
        result = self.run_worker({
            "operation": "test",
            "userId": "dummy-user",
            "pin": "dummy-pin",
        })
        serialized = json.dumps(result)
        self.assertEqual(result["kind"], "error")
        self.assertNotIn("dummy-user", serialized)
        self.assertNotIn("dummy-pin", serialized)

    def test_valid_request_is_dispatched_without_echoing_stdin(self):
        payload = {
            "operation": "test",
            "productId": "1234567890123456789012345",
            "bankCode": "12345678",
            "endpoint": "https://bank.example/fints",
            "userId": "dummy-user",
            "customerId": None,
            "pin": "dummy-pin",
            "clientState": None,
            "tanMechanism": None,
            "tanMedium": None,
        }
        response = {
            "kind": "success",
            "clientState": None,
            "tanMechanism": None,
            "tanMedium": None,
            "accounts": [],
        }
        with patch("worker.run_request", return_value=response):
            result = self.run_worker(payload)
        self.assertEqual(result, response)
        self.assertNotIn("dummy-pin", json.dumps(result))

    def test_oversized_response_is_replaced_with_bounded_error(self):
        payload = {
            "operation": "test",
            "productId": "1234567890123456789012345",
            "bankCode": "12345678",
            "endpoint": "https://bank.example/fints",
            "userId": "dummy-user",
            "customerId": None,
            "pin": "dummy-pin",
            "clientState": None,
            "tanMechanism": None,
            "tanMedium": None,
        }
        with patch("worker.run_request", return_value={"kind": "success", "value": "x" * 2_000_001}):
            result = self.run_worker(payload)
        self.assertEqual(result["kind"], "error")
        self.assertEqual(result["message"], "The FinTS response exceeded the allowed size.")

    def test_subprocess_protocol_uses_stdin_and_keeps_stderr_empty(self):
        payload = {
            "operation": "test",
            "bankCode": "12345678",
            "endpoint": "https://bank.example/fints",
            "userId": "dummy-subprocess-user",
            "pin": "dummy-subprocess-pin",
        }
        result = subprocess.run(
            [sys.executable, str(Path(__file__).parents[1] / "worker.py")],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            check=True,
            env={"PYTHONPATH": str(Path(__file__).parents[1])},
        )
        response = json.loads(result.stdout)
        self.assertEqual(response["kind"], "error")
        self.assertEqual(result.stderr, "")
        self.assertNotIn("dummy-subprocess-user", result.stdout)
        self.assertNotIn("dummy-subprocess-pin", result.stdout)


if __name__ == "__main__":
    unittest.main()
