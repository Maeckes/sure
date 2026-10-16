import socket
import unittest

from sure_fints_worker.protocol import ProtocolError
from sure_fints_worker.security import validate_endpoint


def resolver_for(address):
    def resolve(_host, port, **_kwargs):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, port))]

    return resolve


class EndpointSecurityTest(unittest.TestCase):
    def test_accepts_public_https_endpoint(self):
        self.assertEqual(
            validate_endpoint("https://bank.example/fints", resolver_for("93.184.216.34")),
            "https://bank.example/fints",
        )

    def test_rejects_private_or_loopback_addresses(self):
        for address in ("127.0.0.1", "10.0.0.1", "169.254.169.254"):
            with self.subTest(address=address), self.assertRaises(ProtocolError):
                validate_endpoint("https://bank.example/fints", resolver_for(address))

    def test_rejects_unsafe_url_parts(self):
        values = (
            "http://bank.example/fints",
            "https://user:password@bank.example/fints",
            "https://bank.example/fints?secret=x",
            "https://bank.example/fints#fragment",
            "https://bank.example:8443/fints",
        )
        for value in values:
            with self.subTest(value=value), self.assertRaises(ProtocolError):
                validate_endpoint(value, resolver_for("93.184.216.34"))


if __name__ == "__main__":
    unittest.main()
