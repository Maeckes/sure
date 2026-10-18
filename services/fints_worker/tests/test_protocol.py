import unittest

from sure_fints_worker.protocol import ProtocolError, validate_request


def base_request(operation="test"):
    return {
        "operation": operation,
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


class ProtocolTest(unittest.TestCase):
    def test_requires_product_id(self):
        request = base_request()
        request["productId"] = ""
        with self.assertRaises(ProtocolError) as context:
            validate_request(request)
        self.assertEqual(context.exception.code, "UNSUPPORTED")

    def test_transactions_require_valid_windows(self):
        request = base_request("transactions")
        request["accountWindows"] = [{
            "remoteAccountKey": "a" * 64,
            "startDate": "2026-01-01",
            "endDate": "2026-01-31",
        }]
        self.assertEqual(validate_request(request)["accountWindows"], request["accountWindows"])

    def test_holdings_require_unique_sha256_account_keys(self):
        request = base_request("holdings")
        request["remoteAccountKeys"] = ["b" * 64]
        self.assertEqual(validate_request(request)["remoteAccountKeys"], ["b" * 64])
        request["remoteAccountKeys"] *= 2
        with self.assertRaises(ProtocolError):
            validate_request(request)

    def test_product_id_must_be_exactly_25_characters(self):
        for product_id in ("1" * 24, "1" * 26):
            request = base_request()
            request["productId"] = product_id

            with self.subTest(length=len(product_id)), self.assertRaises(ProtocolError):
                validate_request(request)

    def test_sync_requires_transaction_windows_and_holding_keys(self):
        request = base_request("sync")
        request["accountWindows"] = [{
            "remoteAccountKey": "a" * 64,
            "startDate": "2026-01-01",
            "endDate": "2026-01-31",
        }]
        request["remoteAccountKeys"] = ["b" * 64]

        validated = validate_request(request)

        self.assertEqual(validated["accountWindows"], request["accountWindows"])
        self.assertEqual(validated["remoteAccountKeys"], ["b" * 64])

    def test_continue_accepts_tan_or_decoupled_status_check(self):
        request = base_request("continue")
        request["continuation"] = {
            "operation": "discover",
            "workerState": "opaque-paused-state",
            "tan": None,
        }
        self.assertIsNone(validate_request(request)["continuation"]["tan"])

        request["continuation"]["tan"] = "123456"
        self.assertEqual(validate_request(request)["continuation"]["tan"], "123456")

    def test_continue_rejects_unstructured_or_executable_state(self):
        request = base_request("continue")
        request["continuation"] = {
            "operation": "__import__",
            "workerState": "opaque-paused-state",
            "tan": None,
        }
        with self.assertRaises(ProtocolError):
            validate_request(request)


if __name__ == "__main__":
    unittest.main()
