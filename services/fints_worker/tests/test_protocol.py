import unittest

from sure_fints_worker.protocol import ProtocolError, validate_request


def base_request(operation="test"):
    return {
        "operation": operation,
        "productId": "dummy-registered-product",
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

    def test_rejects_legacy_sync_operation_name(self):
        request = base_request("sync")
        with self.assertRaises(ProtocolError):
            validate_request(request)


if __name__ == "__main__":
    unittest.main()
