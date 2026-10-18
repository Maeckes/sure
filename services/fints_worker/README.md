# Sure FinTS worker

This directory contains a framework-independent, one-request FinTS adapter. It
does not expose a network service. A trusted caller starts `worker.py`, writes
one validated JSON document to stdin, and reads one JSON document from stdout.

Credentials and TANs must never be passed in argv or environment variables.
The caller must disable request/response logging, cap stdout at 2,000,000 bytes,
and terminate the process after its configured timeout. The worker independently
caps stdin and its serialized response at the same size. `python-fints` logging
is disabled because debug output can contain complete FinTS messages.

Runtime dependencies are fully pinned in `requirements.lock`. The registered
FinTS product ID is mandatory and deliberately has no production default.

Supported operations are `test`, `discover`, `transactions`, `holdings`, and
`continue`. `holdings` uses HKWPD through `python-fints.get_holdings()` and
returns decimal monetary/quantity values as strings. Holding snapshots are not
trades, and `acquisitionPrice` is deliberately not labelled as cost basis.

Known follow-ups include full connection-time DNS pinning, TAN mechanism/media
selection, and photoTAN/Flicker variants not exposed as a matrix image by
`python-fints`.

Rails stores paused challenge state only as short-lived Active Record encrypted
data tied to a family, user, and FinTS connection. Text TAN values exist only in
the authenticated POST request and the single stdin document used for
`continue`; decoupled approval uses one bounded continue request per explicit
status check. Neither path uses a background-job argument or keeps a worker
process open between checks.

The Rails integration requires `FINTS_PRODUCT_ID` to contain the operator's
complete 25-character registered FinTS product identifier. It is passed only
as the HKVVB product name. `FINTS_PYTHON`, `FINTS_WORKER_PATH`,
`FINTS_WORKER_TIMEOUT`, and `FINTS_WORKER_OUTPUT_LIMIT` are optional runtime
settings. Credentials, PINs, TANs, and serialized client/dialog state are never
configuration variables; they cross the process boundary only in the single
stdin request.
