from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import re
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Any

import mt940.models
import mt940.processors
import requests
from fints.client import FinTS3PinTanClient, FinTSOperations, NeedRetryResponse, NeedTANResponse
from fints.exceptions import (
    FinTSClientError,
    FinTSClientPINError,
    FinTSClientTemporaryAuthError,
    FinTSConnectionError,
    FinTSDialogError,
    FinTSDialogInitError,
    FinTSError,
    FinTSNoResponseError,
    FinTSSCARequiredError,
    FinTSUnsupportedOperation,
)
from fints.models import SEPAAccount

from .protocol import ProtocolError, _account_keys, _account_windows, error_response
from .security import validate_endpoint


# mt-940 5.x otherwise joins structured :86: fields ?31 (counterparty
# account) and ?32/?33 (counterparty name) in applicant_name.
mt940.processors.DETAIL_KEYS["31"] = "applicant_iban"


@dataclass
class PendingChallenge:
    challenge: NeedTANResponse
    stage: str
    index: int
    accounts: list[dict[str, Any]]
    output: list[dict[str, Any]]


def _b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def _unb64(value: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exc:
        raise ProtocolError("Invalid continuation state.") from exc


def _safe_text(value: Any, maximum: int) -> str | None:
    if value is None:
        return None
    text = str(value).replace("\x00", "").strip()
    return text[:maximum] or None


def _field(value: Any, *names: str) -> Any:
    data = value if isinstance(value, dict) else getattr(value, "data", None)
    for name in names:
        if isinstance(data, dict) and data.get(name) is not None:
            return data[name]
        candidate = getattr(value, name, None)
        if candidate is not None:
            return candidate
    return None


def _date(value: Any) -> str | None:
    if isinstance(value, dt.datetime):
        value = value.date()
    if isinstance(value, dt.date):
        return value.isoformat()
    if value is not None:
        try:
            return dt.date.fromisoformat(str(value)[:10]).isoformat()
        except ValueError:
            return None
    return None


def _decimal_string(value: Any) -> str | None:
    """Serialize a decimal without routing it through float arithmetic."""
    if value is None:
        return None
    try:
        decimal = value if isinstance(value, Decimal) else Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise ProtocolError("The bank returned an invalid decimal value.") from exc
    if not decimal.is_finite():
        raise ProtocolError("The bank returned an invalid decimal value.")
    rendered = format(decimal, "f")
    if "." in rendered:
        rendered = rendered.rstrip("0").rstrip(".")
    return rendered or "0"


def _cents(value: Any) -> int:
    if not isinstance(value, (str, int, float, Decimal)):
        value = _field(value, "amount")
    try:
        return int((Decimal(str(value)) * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise ProtocolError("The bank returned an invalid amount.") from exc


def _safe_response_detail(response: Any, request: dict[str, Any]) -> dict[str, str] | None:
    code = str(getattr(response, "code", ""))
    if not re.fullmatch(r"[39]\d{3}", code):
        return None
    text = _safe_text(getattr(response, "text", None), 160) or "Bank response"
    secrets = [request.get("pin"), request.get("userId"), request.get("customerId")]
    continuation = request.get("continuation")
    if isinstance(continuation, dict):
        secrets.append(continuation.get("tan"))
    for secret in secrets:
        if isinstance(secret, str) and secret:
            text = text.replace(secret, "[redacted]")
    text = re.sub(r"\b[A-Z]{2}\d{2}[A-Z0-9]{10,30}\b", "[redacted]", text, flags=re.I)
    text = re.sub(r"\b\d{6,}\b", "[redacted]", text)
    return {"code": code, "message": text}


def _capture_responses(
    client: FinTS3PinTanClient,
    request: dict[str, Any],
    details: list[dict[str, str]],
) -> None:
    """Capture parsed response codes, never raw FinTS messages."""
    original = getattr(client, "_process_response", None)
    if not callable(original):
        return

    def process(dialog: Any, segment: Any, response: Any):
        detail = _safe_response_detail(response, request)
        if detail and detail not in details and len(details) < 10:
            details.append(detail)
        return original(dialog, segment, response)

    client._process_response = process


def _normalize_iban(value: Any) -> str | None:
    text = _safe_text(value, 100)
    if not text:
        return None
    normalized = re.sub(r"\s+", "", text).upper()
    if not re.fullmatch(r"[A-Z]{2}\d{2}[A-Z0-9]{11,30}", normalized):
        return None
    rearranged = normalized[4:] + normalized[:4]
    converted = "".join(str(ord(char) - 55) if char.isalpha() else char for char in rearranged)
    return normalized if int(converted) % 97 == 1 else None


def _split_iban_prefix(value: Any) -> tuple[str | None, str | None]:
    text = _safe_text(value, 1000)
    if not text:
        return None, None
    compact = re.sub(r"\s+", "", text)
    for length in range(15, min(34, len(compact)) + 1):
        iban = _normalize_iban(compact[:length])
        if not iban:
            continue
        consumed = 0
        index = 0
        while index < len(text) and consumed < length:
            if not text[index].isspace():
                consumed += 1
            index += 1
        return iban, _safe_text(text[index:].lstrip(" -–—,;/"), 1000)
    return None, text


def _account_identifier(value: Any) -> tuple[str | None, str | None]:
    text = _safe_text(value, 100)
    if not text:
        return None, None
    normalized = re.sub(r"\s+", "", text).upper()
    iban = _normalize_iban(normalized)
    if iban:
        return iban, None
    if re.fullmatch(r"[A-Z0-9]{1,34}", normalized):
        return None, normalized
    return None, None


def _counterparty(
    transaction: Any,
    amount: int,
) -> tuple[str | None, str | None, str | None, str | None]:
    applicant_name = _safe_text(
        _field(
            transaction,
            "applicant_name",
            "applicantName",
            "payee",
            "debtor_name",
            "creditor_name",
        ),
        1000,
    )
    applicant_account = _safe_text(
        _field(transaction, "applicant_iban", "applicantIban", "gvc_applicant_iban"),
        100,
    )
    raw_payee = (
        f"{applicant_account}{applicant_name or ''}"
        if isinstance(transaction, mt940.models.Transaction) and applicant_account
        else applicant_name
    )
    if amount < 0:
        name = _safe_text(
            _field(transaction, "creditor_name", "creditorName", "recipient_name"), 1000
        ) or applicant_name
        identifier = (
            _field(transaction, "creditor_iban", "creditorIban", "recipient_iban")
            or applicant_account
        )
    else:
        name = _safe_text(_field(transaction, "debtor_name", "debtorName"), 1000) or applicant_name
        identifier = _field(transaction, "debtor_iban", "debtorIban") or applicant_account
    iban, account_number = _account_identifier(identifier)
    prefixed_iban, cleaned_name = _split_iban_prefix(name)
    return raw_payee, cleaned_name, iban or prefixed_iban, account_number


def _normalize_transaction(transaction: Any) -> dict[str, Any]:
    value_date = _date(_field(transaction, "value_date", "valueDate", "date"))
    booking_date = _date(
        _field(transaction, "booking_date", "bookingDate", "entry_date")
    ) or value_date
    if not booking_date:
        raise ProtocolError("The bank returned a transaction without a booking date.")
    amount_value = _field(transaction, "amount")
    amount = _cents(amount_value)
    currency = _field(amount_value, "currency") or _field(transaction, "currency") or "EUR"
    raw_payee, name, iban, account_number = _counterparty(transaction, amount)
    return {
        "bookingDate": booking_date,
        "valueDate": value_date,
        "amount": amount,
        "currency": str(currency).upper()[:3],
        "payee": raw_payee,
        "counterpartyName": name,
        "counterpartyIban": iban,
        "counterpartyAccountNumber": account_number,
        "purpose": _safe_text(_field(transaction, "purpose", "remittance_information"), 5000),
        "transactionCode": _safe_text(
            _field(transaction, "transaction_code", "transactionCode"), 100
        ),
        "customerReference": _safe_text(
            _field(transaction, "customer_reference", "customerReference", "id"), 500
        ),
        "bankReference": _safe_text(
            _field(transaction, "bank_reference", "bankReference"), 500
        ),
        "endToEndReference": _safe_text(
            _field(transaction, "end_to_end_reference", "endToEndReference"), 500
        ),
        "mandateReference": _safe_text(
            _field(transaction, "mandate_reference", "additional_position_reference"), 500
        ),
        "creditorId": _safe_text(
            _field(transaction, "creditor_id", "applicant_creditor_id"), 500
        ),
    }


def _normalize_holding(holding: Any) -> dict[str, Any]:
    """Normalize an MT535 snapshot without assigning domain semantics to acquisition price."""
    return {
        "isin": _safe_text(_field(holding, "ISIN", "isin"), 32),
        "name": _safe_text(_field(holding, "name"), 500),
        "quantity": _decimal_string(_field(holding, "pieces", "quantity")),
        "unitPrice": _decimal_string(_field(holding, "market_value", "unit_price")),
        "currency": (
            currency.upper()
            if (currency := _safe_text(_field(holding, "value_symbol", "currency"), 3))
            else None
        ),
        "valuationDate": _date(_field(holding, "valuation_date", "price_date")),
        "totalValue": _decimal_string(_field(holding, "total_value", "amount")),
        "acquisitionPrice": _decimal_string(
            _field(holding, "acquisitionprice", "acquisition_price")
        ),
    }


def _account_wire(account: SEPAAccount, information: dict[str, Any] | None = None) -> dict[str, Any]:
    result: dict[str, Any] = {
        "iban": _safe_text(account.iban, 100),
        "bic": _safe_text(account.bic, 100),
        "accountnumber": _safe_text(account.accountnumber, 100),
        "subaccount": _safe_text(account.subaccount, 100),
        "blz": _safe_text(account.blz, 20),
        "name": None,
        "accountType": None,
        "currency": None,
        "supportsBalance": None,
        "supportsTransactions": None,
        "supportsHoldings": None,
    }
    if information:
        operations = information.get("supported_operations")
        result.update(
            name=_safe_text(information.get("product_name"), 500),
            accountType=_safe_text(information.get("type"), 100),
            currency=_safe_text(information.get("currency"), 3),
            supportsBalance=(
                bool(operations.get(FinTSOperations.GET_BALANCE))
                if isinstance(operations, dict)
                else None
            ),
            supportsTransactions=(
                bool(
                    operations.get(FinTSOperations.GET_TRANSACTIONS)
                    or operations.get(FinTSOperations.GET_TRANSACTIONS_XML)
                )
                if isinstance(operations, dict)
                else None
            ),
            supportsHoldings=(
                bool(operations.get(FinTSOperations.GET_HOLDINGS))
                if isinstance(operations, dict)
                else None
            ),
        )
    return result


def _matching_information(account: SEPAAccount, candidates: list[dict[str, Any]]):
    for candidate in candidates:
        if account.iban and candidate.get("iban") and account.iban == candidate["iban"]:
            return candidate
        bank_identifier = candidate.get("bank_identifier")
        bank_code = getattr(bank_identifier, "bank_code", None)
        if (
            account.accountnumber == candidate.get("account_number")
            and (account.subaccount or "") == (candidate.get("subaccount_number") or "")
            and (not account.blz or not bank_code or account.blz == bank_code)
        ):
            return candidate
    return None


def _information_account_wire(
    information: dict[str, Any], default_bank_code: str
) -> dict[str, Any] | None:
    bank_identifier = information.get("bank_identifier")
    bank_code = _safe_text(getattr(bank_identifier, "bank_code", None), 20) or default_bank_code
    iban = _safe_text(information.get("iban"), 100)
    account_number = _safe_text(information.get("account_number"), 100)
    if not iban and not account_number:
        return None
    return _account_wire(
        SEPAAccount(
            iban,
            None,
            account_number,
            _safe_text(information.get("subaccount_number"), 100),
            bank_code,
        ),
        information,
    )


def _remote_id(account: dict[str, Any]) -> str:
    parts = [
        account.get("blz"),
        account.get("accountnumber"),
        account.get("subaccount"),
        account.get("iban"),
    ]
    return "|".join(str(part or "") for part in parts)


def _remote_account_key(account: dict[str, Any]) -> str:
    return hashlib.sha256(f"fints-account:v1:{_remote_id(account)}".encode()).hexdigest()


def _accounts_wire(
    client: FinTS3PinTanClient,
    accounts: list[SEPAAccount],
    default_bank_code: str,
) -> list[dict[str, Any]]:
    information_accounts: list[dict[str, Any]] = []
    try:
        information = client.get_information()
        if isinstance(information, dict) and isinstance(information.get("accounts"), list):
            information_accounts = information["accounts"]
    except Exception:
        pass

    result: list[dict[str, Any]] = []
    matched: set[int] = set()
    for account in accounts:
        information = _matching_information(account, information_accounts)
        if information is not None:
            matched.add(id(information))
        result.append(_account_wire(account, information))

    remote_ids = {_remote_id(account) for account in result}
    for information in information_accounts:
        if id(information) in matched:
            continue
        account = _information_account_wire(information, default_bank_code)
        if account is None or _remote_id(account) in remote_ids:
            continue
        result.append(account)
        remote_ids.add(_remote_id(account))
    return result


def _account_from_wire(value: dict[str, Any]) -> SEPAAccount:
    return SEPAAccount(
        value.get("iban"),
        value.get("bic"),
        value.get("accountnumber"),
        value.get("subaccount"),
        value.get("blz"),
    )


def _new_output(account: dict[str, Any]) -> dict[str, Any]:
    identifier = account.get("iban") or account.get("accountnumber") or ""
    return {
        "remoteId": _remote_id(account),
        "remoteAccountKey": _remote_account_key(account),
        "name": account.get("name") or f"Bank account {str(identifier)[-4:]}".strip(),
        "iban": account.get("iban"),
        "accountNumber": account.get("accountnumber"),
        "accountType": account.get("accountType"),
        "currency": str(account.get("currency") or "EUR").upper()[:3],
        "supportsBalance": account.get("supportsBalance"),
        "supportsTransactions": account.get("supportsTransactions"),
        "supportsHoldings": account.get("supportsHoldings"),
        "balance": None,
        "transactions": [],
        "transactionSync": {
            "status": "not_requested",
            "startDate": None,
            "endDate": None,
            "received": 0,
            "normalized": 0,
            "discarded": 0,
            "includesPending": False,
        },
        "holdings": [],
        "holdingsSync": {
            "status": "not_requested",
            "received": 0,
            "normalized": 0,
            "discarded": 0,
        },
    }


def _normalize_balance(balance: Any) -> tuple[int, str]:
    amount = _field(balance, "amount")
    currency = _field(amount, "currency") or _field(balance, "currency") or "EUR"
    return _cents(amount), str(currency).upper()[:3]


def _make_client(
    request: dict[str, Any],
    state: bytes | None = None,
    details: list[dict[str, str]] | None = None,
) -> FinTS3PinTanClient:
    client = FinTS3PinTanClient(
        request["bankCode"],
        request["userId"],
        request["pin"],
        request["endpoint"],
        customer_id=request["customerId"],
        tan_medium=request["tanMedium"],
        product_id=request["productId"],
        from_data=state,
    )
    client.connection.session.max_redirects = 0
    if details is not None:
        _capture_responses(client, request, details)
    if request["tanMechanism"] and not state:
        client.set_tan_mechanism(request["tanMechanism"])
    return client


def _advance(
    client: FinTS3PinTanClient,
    request: dict[str, Any],
    stage: str,
    index: int,
    accounts: list[dict[str, Any]],
    output: list[dict[str, Any]],
    resumed: Any = None,
):
    operation = (
        request["continuation"]["operation"]
        if request["operation"] == "continue"
        else request["operation"]
    )
    while True:
        if stage == "init":
            challenge = resumed if resumed is not None else client.init_tan_response
            resumed = None
            if isinstance(challenge, NeedTANResponse):
                return PendingChallenge(challenge, stage, index, accounts, output)
            if operation == "test":
                return None
            stage = "accounts"
        elif stage == "accounts":
            try:
                result = resumed if resumed is not None else client.get_sepa_accounts()
            except (FinTSNoResponseError, FinTSUnsupportedOperation):
                result = []
            resumed = None
            if isinstance(result, NeedTANResponse):
                return PendingChallenge(result, stage, index, accounts, output)
            accounts[:] = _accounts_wire(client, result or [], request["bankCode"])
            output[:] = [_new_output(account) for account in accounts]
            stage, index = "balance", 0
        elif stage == "balance":
            if index >= len(accounts):
                if operation == "discover":
                    return None
                if operation == "transactions":
                    stage, index = "transactions", 0
                elif operation == "holdings":
                    stage, index = "holdings", 0
                else:
                    return None
                continue
            if accounts[index].get("supportsBalance") is False:
                index += 1
                continue
            try:
                result = resumed if resumed is not None else client.get_balance(
                    _account_from_wire(accounts[index])
                )
            except (FinTSNoResponseError, FinTSUnsupportedOperation):
                result = None
            resumed = None
            if isinstance(result, NeedTANResponse):
                return PendingChallenge(result, stage, index, accounts, output)
            if result is not None:
                output[index]["balance"], output[index]["currency"] = _normalize_balance(result)
            index += 1
        elif stage == "transactions":
            if index >= len(accounts):
                return None
            windows = {
                window["remoteAccountKey"]: window
                for window in request.get("accountWindows", [])
            }
            window = windows.get(_remote_account_key(accounts[index]))
            if window is None:
                index += 1
                continue
            diagnostic = output[index]["transactionSync"]
            diagnostic.update(
                status="requested",
                startDate=window["startDate"],
                endDate=window["endDate"],
            )
            if accounts[index].get("supportsTransactions") is False:
                diagnostic["status"] = "unsupported"
                index += 1
                continue
            result = resumed if resumed is not None else client.get_transactions(
                _account_from_wire(accounts[index]),
                dt.date.fromisoformat(window["startDate"]),
                dt.date.fromisoformat(window["endDate"]),
                include_pending=False,
            )
            resumed = None
            if isinstance(result, NeedTANResponse):
                return PendingChallenge(result, stage, index, accounts, output)
            transactions = list(result or [])
            normalized = [_normalize_transaction(transaction) for transaction in transactions]
            output[index]["transactions"] = normalized
            diagnostic.update(
                status="completed",
                received=len(transactions),
                normalized=len(normalized),
                discarded=len(transactions) - len(normalized),
            )
            index += 1
        elif stage == "holdings":
            if index >= len(accounts):
                return None
            selected = set(request.get("remoteAccountKeys", []))
            if _remote_account_key(accounts[index]) not in selected:
                index += 1
                continue
            diagnostic = output[index]["holdingsSync"]
            diagnostic["status"] = "requested"
            if accounts[index].get("supportsHoldings") is False:
                diagnostic["status"] = "unsupported"
                index += 1
                continue
            try:
                result = resumed if resumed is not None else client.get_holdings(
                    _account_from_wire(accounts[index])
                )
            except FinTSUnsupportedOperation:
                result = None
                diagnostic["status"] = "unsupported"
            except FinTSNoResponseError:
                result = None
                diagnostic["status"] = "unavailable"
            resumed = None
            if isinstance(result, NeedTANResponse):
                return PendingChallenge(result, stage, index, accounts, output)
            if result is not None:
                holdings = list(result)
                normalized = [_normalize_holding(holding) for holding in holdings]
                output[index]["holdings"] = normalized
                diagnostic.update(
                    status="completed",
                    received=len(holdings),
                    normalized=len(normalized),
                    discarded=len(holdings) - len(normalized),
                )
            index += 1
        else:
            raise ProtocolError("Invalid continuation state.")


def _pack_challenge(
    client: FinTS3PinTanClient,
    dialog: bytes,
    pending: PendingChallenge,
    request: dict[str, Any],
) -> dict[str, Any]:
    operation = (
        request["continuation"]["operation"]
        if request["operation"] == "continue"
        else request["operation"]
    )
    state = {
        "version": 1,
        "operation": operation,
        "client": _b64(client.deconstruct(including_private=True)),
        "dialog": _b64(dialog),
        "challenge": _b64(pending.challenge.get_data()),
        "stage": pending.stage,
        "index": pending.index,
        "accounts": pending.accounts,
        "output": pending.output,
        "accountWindows": request.get("accountWindows"),
        "remoteAccountKeys": request.get("remoteAccountKeys"),
        "decoupled": bool(pending.challenge.decoupled),
    }
    matrix = pending.challenge.challenge_matrix
    image = None
    if matrix and len(matrix) == 2 and str(matrix[0]).startswith("image/"):
        image = f"data:{matrix[0]};base64,{_b64(matrix[1])}"
    return {
        "kind": "challenge",
        "challengeType": "decoupled" if pending.challenge.decoupled else "tan",
        "message": _safe_text(pending.challenge.challenge, 5000)
        or "Confirm the request with your bank.",
        "challengeHtml": _safe_text(pending.challenge.challenge_html, 20_000),
        "challengeImage": image,
        "workerState": json.dumps(state, separators=(",", ":")),
    }


def _success(client: FinTS3PinTanClient, output: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "kind": "success",
        "clientState": _b64(client.deconstruct(including_private=True)),
        "tanMechanism": client.get_current_tan_mechanism(),
        "tanMedium": getattr(client, "selected_tan_medium", None),
        "accounts": output,
    }


def _parse_state(request: dict[str, Any]) -> dict[str, Any]:
    try:
        state = json.loads(request["continuation"]["workerState"])
        if not isinstance(state, dict) or state.get("version") != 1:
            raise ValueError
        if state.get("operation") != request["continuation"]["operation"]:
            raise ValueError
        for key in ("client", "dialog", "challenge", "stage", "accounts", "output"):
            if key not in state:
                raise ValueError
        if state["operation"] == "transactions":
            request["accountWindows"] = _account_windows(state.get("accountWindows"))
        if state["operation"] == "holdings":
            request["remoteAccountKeys"] = _account_keys(state.get("remoteAccountKeys"))
        return state
    except (KeyError, TypeError, ValueError, json.JSONDecodeError, ProtocolError) as exc:
        raise ProtocolError("Invalid continuation state.") from exc


def _run_live(request: dict[str, Any], details: list[dict[str, str]]) -> dict[str, Any]:
    validate_endpoint(request["endpoint"])
    if request["operation"] == "continue":
        state = _parse_state(request)
        client = _make_client(request, _unb64(state["client"]), details)
        challenge = NeedRetryResponse.from_data(_unb64(state["challenge"]))
        if not isinstance(challenge, NeedTANResponse):
            raise ProtocolError("Invalid continuation state.")
        challenge.decoupled = bool(state.get("decoupled", False))
        tan = request["continuation"]["tan"]
        if not challenge.decoupled and not tan:
            raise ProtocolError("A TAN is required.", "AUTHENTICATION_FAILED")
        with client.resume_dialog(_unb64(state["dialog"])):
            resumed = client.send_tan(challenge, tan or "")
            pending = _advance(
                client,
                request,
                state["stage"],
                int(state["index"]),
                state["accounts"],
                state["output"],
                resumed,
            )
            if pending:
                dialog = client.pause_dialog()
        return _pack_challenge(client, dialog, pending, request) if pending else _success(
            client, state["output"]
        )

    state = _unb64(request["clientState"]) if request["clientState"] else None
    client = _make_client(request, state, details)
    output: list[dict[str, Any]] = []
    accounts: list[dict[str, Any]] = []
    with client:
        pending = _advance(client, request, "init", 0, accounts, output)
        if pending:
            dialog = client.pause_dialog()
    return _pack_challenge(client, dialog, pending, request) if pending else _success(client, output)


def run_request(request: dict[str, Any]) -> dict[str, Any]:
    details: list[dict[str, str]] = []
    try:
        return _run_live(request, details)
    except ProtocolError as exc:
        return error_response(exc.code, exc.public_message, details)
    except (FinTSClientPINError, FinTSClientTemporaryAuthError):
        return error_response(
            "AUTHENTICATION_FAILED", "The bank rejected the credentials or TAN.", details
        )
    except (FinTSConnectionError, requests.RequestException, OSError):
        return error_response("NETWORK_ERROR", "The bank could not be reached.", details)
    except FinTSUnsupportedOperation:
        return error_response(
            "UNSUPPORTED", "The bank does not support this FinTS operation.", details
        )
    except FinTSSCARequiredError:
        return error_response(
            "UNSUPPORTED", "The bank requires an unsupported SCA flow.", details
        )
    except FinTSNoResponseError:
        return error_response("BANK_ERROR", "The bank returned no usable response.", details)
    except FinTSDialogInitError:
        return error_response(
            "BANK_ERROR", "The FinTS dialog could not be initialized.", details
        )
    except (FinTSClientError, FinTSDialogError, FinTSError):
        return error_response("BANK_ERROR", "The bank rejected the FinTS request.", details)
    except Exception:
        return error_response(
            "BANK_ERROR", "The FinTS adapter could not process the response.", details
        )
