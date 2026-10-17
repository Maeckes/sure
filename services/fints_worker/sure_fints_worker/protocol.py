from __future__ import annotations

import datetime as dt
from typing import Any


ERROR_CODES = {"AUTHENTICATION_FAILED", "NETWORK_ERROR", "UNSUPPORTED", "BANK_ERROR"}
OPERATIONS = {"test", "discover", "transactions", "holdings", "sync", "continue"}
ACCOUNT_KEY_LENGTH = 64


class ProtocolError(Exception):
    def __init__(self, public_message: str, code: str = "BANK_ERROR"):
        super().__init__(public_message)
        self.public_message = public_message
        self.code = code


def error_response(
    code: str,
    message: str,
    details: list[dict[str, str]] | None = None,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "kind": "error",
        "code": code if code in ERROR_CODES else "BANK_ERROR",
        "message": message,
    }
    if details:
        result["details"] = details[:10]
    return result


def _string(value: Any, *, minimum: int = 0, maximum: int = 2_000_000) -> str:
    if not isinstance(value, str) or not minimum <= len(value) <= maximum:
        raise ProtocolError("Invalid worker request.")
    return value


def _nullable_string(value: Any, *, maximum: int = 2_000_000) -> str | None:
    if value is None:
        return None
    return _string(value, maximum=maximum)


def _date(value: Any) -> str:
    value = _string(value, minimum=10, maximum=10)
    try:
        return dt.date.fromisoformat(value).isoformat()
    except ValueError as exc:
        raise ProtocolError("Invalid worker request.") from exc


def _account_key(value: Any) -> str:
    key = _string(value, minimum=ACCOUNT_KEY_LENGTH, maximum=ACCOUNT_KEY_LENGTH)
    if any(character not in "0123456789abcdef" for character in key):
        raise ProtocolError("Invalid worker request.")
    return key


def _account_windows(value: Any) -> list[dict[str, str]]:
    if not isinstance(value, list) or len(value) > 1000:
        raise ProtocolError("Invalid worker request.")
    result: list[dict[str, str]] = []
    seen: set[str] = set()
    for item in value:
        if not isinstance(item, dict):
            raise ProtocolError("Invalid worker request.")
        key = _account_key(item.get("remoteAccountKey"))
        start_date = _date(item.get("startDate"))
        end_date = _date(item.get("endDate"))
        if key in seen or start_date > end_date:
            raise ProtocolError("Invalid worker request.")
        seen.add(key)
        result.append({
            "remoteAccountKey": key,
            "startDate": start_date,
            "endDate": end_date,
        })
    return result


def _account_keys(value: Any) -> list[str]:
    if not isinstance(value, list) or len(value) > 1000:
        raise ProtocolError("Invalid worker request.")
    keys = [_account_key(item) for item in value]
    if len(keys) != len(set(keys)):
        raise ProtocolError("Invalid worker request.")
    return keys


def validate_request(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ProtocolError("Invalid worker request.")
    operation = _string(value.get("operation"), minimum=1, maximum=20)
    if operation not in OPERATIONS:
        raise ProtocolError("Invalid worker request.")
    product_id = _string(value.get("productId", ""), maximum=200).strip()
    if not product_id:
        raise ProtocolError("A registered FinTS product id is required.", "UNSUPPORTED")

    request: dict[str, Any] = {
        "operation": operation,
        "productId": product_id,
        "bankCode": _string(value.get("bankCode"), minimum=8, maximum=8),
        "endpoint": _string(value.get("endpoint"), minimum=1, maximum=500),
        "userId": _string(value.get("userId"), minimum=1, maximum=200),
        "customerId": _nullable_string(value.get("customerId"), maximum=200),
        "pin": _string(value.get("pin"), minimum=1, maximum=200),
        "clientState": _nullable_string(value.get("clientState")),
        "tanMechanism": _nullable_string(value.get("tanMechanism"), maximum=100),
        "tanMedium": _nullable_string(value.get("tanMedium"), maximum=200),
    }
    if not request["bankCode"].isdigit():
        raise ProtocolError("Invalid worker request.")

    if operation in {"transactions", "sync"}:
        request["accountWindows"] = _account_windows(value.get("accountWindows"))
    if operation in {"holdings", "sync"}:
        request["remoteAccountKeys"] = _account_keys(value.get("remoteAccountKeys"))
    if operation == "continue":
        continuation = value.get("continuation")
        if not isinstance(continuation, dict):
            raise ProtocolError("Invalid worker request.")
        original = _string(continuation.get("operation"), minimum=1, maximum=20)
        if original not in {"test", "discover", "transactions", "holdings", "sync"}:
            raise ProtocolError("Invalid worker request.")
        request["continuation"] = {
            "operation": original,
            "workerState": _string(continuation.get("workerState"), minimum=1),
            "tan": _nullable_string(continuation.get("tan"), maximum=100),
        }
    return request
