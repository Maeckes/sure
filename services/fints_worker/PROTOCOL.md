# FinTS worker protocol v1

The worker reads exactly one UTF-8 JSON object from stdin and writes exactly one
UTF-8 JSON object to stdout. It writes no diagnostics to stderr. The maximum
request and response size is 2,000,000 bytes. The future Sure caller must start
the process without a shell, pass secrets only in stdin, ignore stderr, enforce
the same response limit, and kill the process when its configured timeout
expires.

## Common request

```json
{
  "operation": "test | discover | transactions | holdings | continue",
  "productId": "registered-product-id",
  "bankCode": "12345678",
  "endpoint": "https://bank.example/fints",
  "userId": "dummy-user",
  "customerId": null,
  "pin": "dummy-pin",
  "clientState": null,
  "tanMechanism": null,
  "tanMedium": null
}
```

`transactions` adds independently calculated date windows for selected accounts:

```json
{
  "accountWindows": [
    {
      "remoteAccountKey": "64-lowercase-hex-characters",
      "startDate": "2026-01-01",
      "endDate": "2026-01-31"
    }
  ]
}
```

`holdings` adds the selected depot account identities:

```json
{
  "remoteAccountKeys": ["64-lowercase-hex-characters"]
}
```

`continue` resumes a challenge returned by the worker:

```json
{
  "operation": "continue",
  "continuation": {
    "operation": "holdings",
    "workerState": "opaque-sensitive-state",
    "tan": "dummy-tan"
  }
}
```

`workerState` and `clientState` are sensitive and must be encrypted at rest.
`tan` must never be persisted or put into job arguments.

## Success

```json
{
  "kind": "success",
  "clientState": "base64-sensitive-state",
  "tanMechanism": "942",
  "tanMedium": null,
  "accounts": [
    {
      "remoteId": "worker-private-source-identity",
      "remoteAccountKey": "stable-sha256-key",
      "name": "Dummy account",
      "iban": null,
      "accountNumber": "1234567",
      "accountType": "1",
      "currency": "EUR",
      "supportsBalance": true,
      "supportsTransactions": false,
      "supportsHoldings": true,
      "balance": 12345,
      "transactions": [],
      "transactionSync": {
        "status": "not_requested",
        "startDate": null,
        "endDate": null,
        "received": 0,
        "normalized": 0,
        "discarded": 0,
        "includesPending": false
      },
      "holdings": [
        {
          "isin": "DE000DUMMY001",
          "name": "Dummy Equity ETF",
          "quantity": "12.34567890123456789",
          "unitPrice": "101.23456789",
          "currency": "EUR",
          "valuationDate": "2026-10-15",
          "totalValue": "1249.81",
          "acquisitionPrice": "87.654321"
        }
      ],
      "holdingsSync": {
        "status": "completed",
        "received": 1,
        "normalized": 1,
        "discarded": 0
      }
    }
  ]
}
```

Transaction amounts and balances are integer minor units, matching the extracted
worker's existing contract. Holding quantities and monetary fields are decimal
strings to avoid JSON floating-point loss. `acquisitionPrice` is upstream data,
not a declaration that the value is Sure cost basis.

## Challenge

```json
{
  "kind": "challenge",
  "challengeType": "tan | decoupled",
  "message": "Sanitized bank challenge",
  "challengeHtml": null,
  "challengeImage": null,
  "workerState": "opaque-sensitive-state"
}
```

## Error

```json
{
  "kind": "error",
  "code": "AUTHENTICATION_FAILED | NETWORK_ERROR | UNSUPPORTED | BANK_ERROR",
  "message": "Sanitized public message",
  "details": [{"code": "9050", "message": "Sanitized bank response"}]
}
```

Raw FinTS messages and raw exception strings are never returned.
