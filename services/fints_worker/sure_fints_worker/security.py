from __future__ import annotations

import ipaddress
import socket
from collections.abc import Callable
from urllib.parse import urlsplit

from .protocol import ProtocolError


Resolver = Callable[..., list[tuple]]


def validate_endpoint(endpoint: str, resolver: Resolver = socket.getaddrinfo) -> str:
    """Require a public HTTPS endpoint and reject obvious SSRF targets."""
    try:
        url = urlsplit(endpoint)
        if (
            url.scheme != "https"
            or not url.hostname
            or url.username is not None
            or url.password is not None
            or url.query
            or url.fragment
            or (url.port is not None and url.port != 443)
        ):
            raise ValueError
        addresses = resolver(url.hostname, url.port or 443, type=socket.SOCK_STREAM)
        if not addresses:
            raise ValueError
        for address in addresses:
            if not ipaddress.ip_address(address[4][0]).is_global:
                raise ValueError
    except (OSError, ValueError, TypeError) as exc:
        raise ProtocolError("The FinTS endpoint is not allowed.", "NETWORK_ERROR") from exc
    return endpoint
