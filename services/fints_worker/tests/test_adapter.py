import datetime as dt
import json
import unittest
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from fints.exceptions import (
    FinTSClientTemporaryAuthError,
    FinTSDialogInitError,
    FinTSUnsupportedOperation,
)
from fints.models import SEPAAccount
from fints.utils import mt940_to_array

from sure_fints_worker import adapter


ACCOUNT = SEPAAccount("DE02120300000000202051", "BYLADEM1001", "202051", "", "12030000")
DEPOT = SEPAAccount(None, None, "7654321", "", "12030000")


def account_info(account, *, balance=True, transactions=True, holdings=False, name="Dummy account"):
    return {
        "iban": account.iban,
        "account_number": account.accountnumber,
        "subaccount_number": account.subaccount,
        "bank_identifier": SimpleNamespace(bank_code=account.blz),
        "type": "1",
        "currency": "EUR",
        "product_name": name,
        "supported_operations": {
            adapter.FinTSOperations.GET_BALANCE: balance,
            adapter.FinTSOperations.GET_TRANSACTIONS: transactions,
            adapter.FinTSOperations.GET_HOLDINGS: holdings,
        },
    }


def load_holding_fixture():
    path = Path(__file__).parent / "fixtures" / "holdings.json"
    rows = json.loads(path.read_text(encoding="utf-8"))
    return [
        SimpleNamespace(
            ISIN=row["isin"],
            name=row["name"],
            pieces=Decimal(row["quantity"]),
            market_value=Decimal(row["unit_price"]),
            value_symbol=row["currency"],
            valuation_date=dt.date.fromisoformat(row["valuation_date"]),
            total_value=Decimal(row["total_value"]),
            acquisitionprice=(
                Decimal(row["acquisition_price"])
                if row["acquisition_price"] is not None
                else None
            ),
        )
        for row in rows
    ]


class FakeClient:
    init_tan_response = None

    def __init__(self, *args, **kwargs):
        self.constructor = (args, kwargs)
        self.connection = SimpleNamespace(session=SimpleNamespace(max_redirects=30))
        self.selected_tan_medium = kwargs.get("tan_medium")
        self.mechanism = "942"

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def resume_dialog(self, _dialog):
        return self

    def _process_response(self, _dialog, _segment, _response):
        return None

    def set_tan_mechanism(self, mechanism):
        self.mechanism = mechanism

    def get_current_tan_mechanism(self):
        return self.mechanism

    def deconstruct(self, including_private=False):
        self.assert_private = including_private
        return b"serialized-client-state"

    def pause_dialog(self):
        return b"serialized-dialog-state"

    def get_sepa_accounts(self):
        return [ACCOUNT]

    def get_information(self):
        return {"accounts": [account_info(ACCOUNT)]}

    def get_balance(self, _account):
        amount = SimpleNamespace(amount=Decimal("123.45"), currency="EUR")
        return SimpleNamespace(amount=amount)

    def get_transactions(self, _account, start_date, end_date, include_pending=True):
        assert start_date == dt.date(2026, 1, 1)
        assert end_date == dt.date(2026, 1, 31)
        assert include_pending is False
        return [SimpleNamespace(data={
            "date": dt.date(2026, 1, 3),
            "entry_date": dt.date(2026, 1, 2),
            "amount": Decimal("-12.34"),
            "currency": "EUR",
            "applicant_name": "Dummy Shop",
            "purpose": "Mock purchase",
        })]


class HoldingsClient(FakeClient):
    holding_requests = []

    def get_sepa_accounts(self):
        return [ACCOUNT]

    def get_information(self):
        return {
            "accounts": [
                account_info(ACCOUNT, holdings=False, name="Dummy current account"),
                account_info(
                    DEPOT,
                    balance=False,
                    transactions=False,
                    holdings=True,
                    name="Dummy securities account",
                ),
            ]
        }

    def get_holdings(self, account):
        type(self).holding_requests.append(account.accountnumber)
        return load_holding_fixture()


class PartialBalanceClient(HoldingsClient):
    def get_balance(self, account):
        if account.accountnumber == DEPOT.accountnumber:
            raise AssertionError("unsupported balance operation must be skipped")
        return super().get_balance(account)


class PartialTransactionFailureClient(HoldingsClient):
    def get_information(self):
        information = super().get_information()
        information["accounts"][1]["supported_operations"][adapter.FinTSOperations.GET_TRANSACTIONS] = True
        return information

    def get_transactions(self, account, start_date, end_date, include_pending=True):
        if account.accountnumber == DEPOT.accountnumber:
            raise FinTSDialogInitError("dummy per-account rejection")
        return super().get_transactions(account, start_date, end_date, include_pending)


class UnsupportedAccountsClient(HoldingsClient):
    def get_sepa_accounts(self):
        raise FinTSUnsupportedOperation("dummy unsupported HKSPA")


class WarningClient(FakeClient):
    def __enter__(self):
        for code, text in (
            ("3060", "Warnings are present"),
            ("3050", "BPD is no longer current"),
            ("3050", "UPD is no longer current"),
            ("3920", "Allowed authentication mechanisms"),
        ):
            self._process_response(None, None, SimpleNamespace(code=code, text=text))
        return self


class UnsupportedHoldingsClient(HoldingsClient):
    def get_information(self):
        information = super().get_information()
        information["accounts"][1]["supported_operations"][adapter.FinTSOperations.GET_HOLDINGS] = None
        return information

    def get_holdings(self, _account):
        raise FinTSUnsupportedOperation("dummy unsupported HKWPD")


class FakeChallenge:
    decoupled = False
    challenge = "Enter the test TAN"
    challenge_html = None
    challenge_matrix = None

    def get_data(self):
        return b"serialized-challenge"


class DecoupledChallenge(FakeChallenge):
    decoupled = True
    challenge = "Approve in the banking app"


class MatrixChallenge(FakeChallenge):
    challenge_matrix = ("image/png", b"dummy-image-bytes")


class DecoupledChallengeClient(FakeClient):
    def get_sepa_accounts(self):
        return DecoupledChallenge()

    def send_tan(self, _challenge, tan):
        assert tan == ""
        return [ACCOUNT]


class PendingDecoupledClient(DecoupledChallengeClient):
    def send_tan(self, _challenge, tan):
        assert tan == ""
        return DecoupledChallenge()


class FailedDecoupledClient(DecoupledChallengeClient):
    def send_tan(self, _challenge, _tan):
        raise FinTSClientTemporaryAuthError("private bank detail")


class MatrixChallengeClient(FakeClient):
    def get_sepa_accounts(self):
        return MatrixChallenge()


class HoldingsChallengeClient(HoldingsClient):
    def get_holdings(self, _account):
        return FakeChallenge()

    def send_tan(self, _challenge, tan):
        assert tan == "123456"
        return load_holding_fixture()


class BankErrorClient(FakeClient):
    def __enter__(self):
        self._process_response(
            None,
            None,
            SimpleNamespace(
                code="9050",
                text="Rejected dummy-user dummy-pin DE02120300000000202051 123456789",
            ),
        )
        return self

    def _process_response(self, _dialog, _segment, _response):
        raise FinTSDialogInitError("raw exception with dummy-pin")


def request(operation="discover"):
    value = {
        "operation": operation,
        "productId": "dummy-registered-product-id",
        "bankCode": "12030000",
        "endpoint": "https://bank.example/fints",
        "userId": "dummy-user",
        "customerId": None,
        "pin": "dummy-pin",
        "clientState": None,
        "tanMechanism": None,
        "tanMedium": None,
    }
    if operation == "transactions":
        value["accountWindows"] = [{
            "remoteAccountKey": adapter._remote_account_key(adapter._account_wire(ACCOUNT)),
            "startDate": "2026-01-01",
            "endDate": "2026-01-31",
        }]
    if operation == "holdings":
        value["remoteAccountKeys"] = [
            adapter._remote_account_key(adapter._account_wire(DEPOT))
        ]
    return value


class AdapterTest(unittest.TestCase):
    def setUp(self):
        patches = [
            patch.object(adapter, "validate_endpoint", side_effect=lambda value: value),
            patch.object(adapter, "FinTS3PinTanClient", FakeClient),
        ]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)

    def test_discover_combines_sepa_and_upd_accounts(self):
        with patch.object(adapter, "FinTS3PinTanClient", HoldingsClient):
            result = adapter.run_request(request())
        self.assertEqual(result["kind"], "success")
        self.assertEqual([item["name"] for item in result["accounts"]], [
            "Dummy current account",
            "Dummy securities account",
        ])
        self.assertIsNone(result["accounts"][1]["iban"])
        self.assertTrue(result["accounts"][1]["supportsHoldings"])

    def test_discover_skips_unsupported_balance_without_losing_depot(self):
        with patch.object(adapter, "FinTS3PinTanClient", PartialBalanceClient):
            result = adapter.run_request(request())
        self.assertEqual(result["kind"], "success")
        self.assertEqual(len(result["accounts"]), 2)
        self.assertEqual(result["accounts"][0]["balance"], 12345)
        self.assertIsNone(result["accounts"][1]["balance"])

    def test_upd_discovery_survives_unsupported_hkspa(self):
        with patch.object(adapter, "FinTS3PinTanClient", UnsupportedAccountsClient):
            result = adapter.run_request(request())
        self.assertEqual(result["kind"], "success")
        self.assertEqual(len(result["accounts"]), 2)

    def test_warning_response_codes_are_not_fatal(self):
        with patch.object(adapter, "FinTS3PinTanClient", WarningClient):
            result = adapter.run_request(request())
        self.assertEqual(result["kind"], "success")

    def test_transactions_preserve_dates_amounts_and_structured_counterparty(self):
        result = adapter.run_request(request("transactions"))
        transaction = result["accounts"][0]["transactions"][0]
        self.assertEqual(transaction["amount"], -1234)
        self.assertEqual(transaction["bookingDate"], "2026-01-02")
        self.assertEqual(transaction["valueDate"], "2026-01-03")
        self.assertEqual(transaction["counterpartyName"], "Dummy Shop")
        self.assertEqual(result["accounts"][0]["transactionSync"]["status"], "completed")

    def test_transaction_failure_is_isolated_per_account(self):
        value = request("transactions")
        value["accountWindows"].append({
            "remoteAccountKey": adapter._remote_account_key(adapter._account_wire(DEPOT)),
            "startDate": "2026-01-01",
            "endDate": "2026-01-31",
        })
        with patch.object(adapter, "FinTS3PinTanClient", PartialTransactionFailureClient):
            result = adapter.run_request(value)

        self.assertEqual(result["kind"], "success")
        self.assertEqual(result["accounts"][0]["transactionSync"]["status"], "completed")
        self.assertEqual(result["accounts"][1]["transactionSync"]["status"], "unavailable")

    def test_mt940_keeps_account_identifier_name_and_purpose_separate(self):
        statement = """:20:DUMMY
:25:DE00123456780000000001
:28C:1/1
:60F:C261001EUR100,00
:61:2610021002D12,34NTRFDUMMY//BANKREF
:86:020?00UEBERWEISUNG?20SVWZ+Steuerzahlung?31DE02120300000000202051?32Finanzamt Prenzlauer Berg
:62F:C261002EUR87,66
-"""
        normalized = adapter._normalize_transaction(mt940_to_array(statement)[0])
        self.assertEqual(normalized["counterpartyName"], "Finanzamt Prenzlauer Berg")
        self.assertEqual(normalized["counterpartyIban"], "DE02120300000000202051")
        self.assertEqual(normalized["purpose"], "Steuerzahlung")

    def test_holdings_calls_hkwpd_only_for_selected_capable_account(self):
        HoldingsClient.holding_requests = []
        with patch.object(adapter, "FinTS3PinTanClient", HoldingsClient):
            result = adapter.run_request(request("holdings"))
        depot = result["accounts"][1]
        self.assertEqual(HoldingsClient.holding_requests, [DEPOT.accountnumber])
        self.assertEqual(depot["holdingsSync"]["status"], "completed")
        self.assertEqual(depot["holdingsSync"]["received"], 2)
        self.assertEqual(depot["holdings"][0], {
            "isin": "DE000DUMMY001",
            "name": "Dummy Global Equity ETF",
            "quantity": "12.34567890123456789",
            "unitPrice": "101.23456789",
            "currency": "EUR",
            "valuationDate": "2026-10-15",
            "totalValue": "1249.81",
            "acquisitionPrice": "87.654321",
        })
        self.assertNotIn("trade", json.dumps(result).lower())
        self.assertNotIn("costBasis", json.dumps(result))

    def test_unsupported_hkwpd_is_per_account_nonfatal(self):
        with patch.object(adapter, "FinTS3PinTanClient", UnsupportedHoldingsClient):
            result = adapter.run_request(request("holdings"))
        self.assertEqual(result["kind"], "success")
        self.assertEqual(result["accounts"][1]["holdings"], [])
        self.assertEqual(result["accounts"][1]["holdingsSync"]["status"], "unsupported")

    def test_holdings_tan_challenge_resumes_at_same_account(self):
        with patch.object(adapter, "FinTS3PinTanClient", HoldingsChallengeClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ):
            first = adapter.run_request(request("holdings"))
        self.assertEqual(first["kind"], "challenge")
        self.assertNotIn("dummy-pin", first["workerState"])

        continued = request("continue")
        continued["continuation"] = {
            "operation": "holdings",
            "workerState": first["workerState"],
            "tan": "123456",
        }
        with patch.object(adapter, "FinTS3PinTanClient", HoldingsChallengeClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ), patch.object(adapter.NeedRetryResponse, "from_data", return_value=FakeChallenge()):
            result = adapter.run_request(continued)
        self.assertEqual(result["kind"], "success")
        self.assertEqual(result["accounts"][1]["holdingsSync"]["status"], "completed")

    def test_decoupled_challenge_resumes_without_a_tan(self):
        with patch.object(adapter, "FinTS3PinTanClient", DecoupledChallengeClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ):
            first = adapter.run_request(request())
        self.assertEqual(first["challengeType"], "decoupled")

        continued = request("continue")
        continued["continuation"] = {
            "operation": "discover",
            "workerState": first["workerState"],
            "tan": None,
        }
        with patch.object(adapter, "FinTS3PinTanClient", DecoupledChallengeClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ), patch.object(
            adapter.NeedRetryResponse, "from_data", return_value=DecoupledChallenge()
        ):
            result = adapter.run_request(continued)

        self.assertEqual(result["kind"], "success")
        self.assertEqual(len(result["accounts"]), 1)

    def test_decoupled_pending_returns_fresh_paused_state(self):
        with patch.object(adapter, "FinTS3PinTanClient", DecoupledChallengeClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ):
            first = adapter.run_request(request())
        continued = request("continue")
        continued["continuation"] = {
            "operation": "discover",
            "workerState": first["workerState"],
            "tan": None,
        }

        with patch.object(adapter, "FinTS3PinTanClient", PendingDecoupledClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ), patch.object(
            adapter.NeedRetryResponse, "from_data", return_value=DecoupledChallenge()
        ):
            result = adapter.run_request(continued)

        self.assertEqual(result["kind"], "challenge")
        self.assertEqual(result["challengeType"], "decoupled")
        self.assertTrue(result["workerState"])

    def test_decoupled_failure_is_safely_mapped(self):
        with patch.object(adapter, "FinTS3PinTanClient", DecoupledChallengeClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ):
            first = adapter.run_request(request())
        continued = request("continue")
        continued["continuation"] = {
            "operation": "discover",
            "workerState": first["workerState"],
            "tan": None,
        }

        with patch.object(adapter, "FinTS3PinTanClient", FailedDecoupledClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ), patch.object(
            adapter.NeedRetryResponse, "from_data", return_value=DecoupledChallenge()
        ):
            result = adapter.run_request(continued)

        self.assertEqual(result["kind"], "error")
        self.assertEqual(result["code"], "AUTHENTICATION_FAILED")
        self.assertNotIn("private bank detail", json.dumps(result))

    def test_matrix_challenge_is_bounded_base64_data(self):
        with patch.object(adapter, "FinTS3PinTanClient", MatrixChallengeClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ):
            result = adapter.run_request(request())

        self.assertEqual(result["kind"], "challenge")
        self.assertTrue(result["challengeImage"].startswith("data:image/png;base64,"))

    def test_challenge_text_is_redacted(self):
        challenge = FakeChallenge()
        challenge.challenge = "dummy-user dummy-pin DE02120300000000202051 123456789"

        class RedactedChallengeClient(FakeClient):
            def get_sepa_accounts(self):
                return challenge

        with patch.object(adapter, "FinTS3PinTanClient", RedactedChallengeClient), patch.object(
            adapter, "NeedTANResponse", FakeChallenge
        ):
            result = adapter.run_request(request())

        serialized = json.dumps(result)
        self.assertNotIn("dummy-user", serialized)
        self.assertNotIn("dummy-pin", serialized)
        self.assertNotIn("DE02120300000000202051", serialized)
        self.assertNotIn("123456789", serialized)

    def test_structured_error_details_are_redacted(self):
        with patch.object(adapter, "FinTS3PinTanClient", BankErrorClient):
            result = adapter.run_request(request())
        serialized = json.dumps(result)
        self.assertEqual(result["code"], "BANK_ERROR")
        self.assertNotIn("dummy-user", serialized)
        self.assertNotIn("dummy-pin", serialized)
        self.assertNotIn("DE02120300000000202051", serialized)
        self.assertNotIn("123456789", serialized)

    def test_unexpected_exception_text_is_never_returned(self):
        with patch.object(
            adapter,
            "_run_live",
            side_effect=RuntimeError("dummy-pin dummy-user private dialog state"),
        ):
            result = adapter.run_request(request())
        serialized = json.dumps(result)
        self.assertEqual(result["message"], "The FinTS adapter could not process the response.")
        self.assertNotIn("dummy-pin", serialized)
        self.assertNotIn("dummy-user", serialized)
        self.assertNotIn("dialog state", serialized)

    def test_invalid_decimal_holding_is_safely_rejected(self):
        with self.assertRaises(adapter.ProtocolError):
            adapter._normalize_holding(SimpleNamespace(
                ISIN="DE000DUMMY003",
                name="Invalid dummy holding",
                pieces="not-a-number",
            ))


if __name__ == "__main__":
    unittest.main()
