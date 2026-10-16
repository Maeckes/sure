#!/usr/bin/env python3
"""Secret-safe JSON/stdin entry point for Sure's private FinTS worker."""

from __future__ import annotations

import json
import logging
import sys

from sure_fints_worker.adapter import run_request
from sure_fints_worker.protocol import ProtocolError, error_response, validate_request


MAX_MESSAGE_BYTES = 2_000_000

# python-fints can log complete protocol messages at debug level. Never enable
# library logging in this process.
logging.disable(logging.CRITICAL)


def main() -> int:
    try:
        raw = sys.stdin.read(MAX_MESSAGE_BYTES + 1)
        if len(raw.encode("utf-8")) > MAX_MESSAGE_BYTES:
            raise ProtocolError("Invalid worker request.")
        request = validate_request(json.loads(raw))
        result = run_request(request)
    except ProtocolError as exc:
        result = error_response(exc.code, exc.public_message)
    except Exception:
        result = error_response("BANK_ERROR", "The bank rejected the FinTS request.")

    serialized = json.dumps(result, ensure_ascii=False, separators=(",", ":"))
    if len(serialized.encode("utf-8")) > MAX_MESSAGE_BYTES:
        serialized = json.dumps(
            error_response("BANK_ERROR", "The FinTS response exceeded the allowed size."),
            separators=(",", ":"),
        )
    sys.stdout.write(serialized)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
