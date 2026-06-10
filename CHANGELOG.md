# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

## [0.6.1] - 2026-06-10

### Fixed

- `h1:accept_upgrade/3` now strips any caller-supplied `Connection` or
  `Upgrade` headers (case-insensitive) from ExtraHeaders before adding
  its own, so the 101 response carries exactly one of each with h1's
  canonical values. Previously a caller passing them produced duplicate
  headers, which spec-strict WebSocket clients (Safari, undici) reject.

## [0.6.0] - 2026-06-05

### Added

- `max_header_block_size` bounds the total bytes of a message's header
  block (default 64 KB), configurable on `start_server`/`connect`. It
  covers request and response headers and trailers. Over-limit input is
  rejected with `header_block_too_large`, which maps to HTTP 431.

### Changed

- Less per-request work on the hot paths: the body is measured without
  being copied, each header line is parsed in a single scan, and the
  response header block is built in one pass. No behaviour change.

### Security

- Close an unbounded-buffer path in header parsing. A peer could otherwise
  grow the parse buffer without end by dribbling a header line that never
  terminates, or by stacking headers that each stayed under the per-field
  size and header-count limits. The new header-block cap bounds it.

## [0.5.0] - 2026-06-05

### Added

- `h1:respond/5` sends status, headers, and body in a single socket write
  and ends the stream. A `Content-Length` is added when the headers carry
  neither `Content-Length` nor `Transfer-Encoding`, so a fully-known body
  is sent fixed-length in one `gen_tcp:send` rather than the two writes
  `send_response/4` + `send_data/4` would do.

## [0.4.0] - 2026-06-04

### Changed

- Server `request` and `upgrade` events now deliver the full origin-form
  target (path plus query) as `Path`; previously the query string was
  dropped. Behavior change to the event's `Path`.

## [0.3.0] - 2026-06-02

### Added

- Listeners can bind a specific address or family. `start_server/2,3`
  accept `ip => inet:ip_address()` (an 8-tuple selects IPv6) and
  `inet6 => boolean()` (bind the IPv6 wildcard `::`) for both the `tcp`
  and `ssl` transports.

## [0.2.3] - 2026-05-28

### Changed

- Build and dialyzer clean on OTP 27, 28 and 29. Replaces the legacy
  `catch Expr` operator (removed in OTP 29) with `try ... catch _:_ -> ok end`,
  retypes `upgrade_from` as `gen_statem:from()`, and drops a handful of
  unreachable clauses surfaced by `unmatched_returns`.

### Tests / CI

- Interop suite's `docker_run` now picks the last non-empty stdout line
  as the container id so cold image pulls don't confuse it.
- New GitHub Actions matrix runs build, xref, dialyze and tests on
  OTP 27, 28 and 29 (rebar3 3.27.0).

## [0.2.2] - 2026-05-20

### Security

- Reject chunked bodies whose declared chunk size exceeds `max_body_size`
  before buffering, and cap the chunk-extension scan at 4096 bytes. Both
  paths previously let a peer grow the parser buffer without bound.
- Enforce `max_empty_lines` using the parser's persistent counter so a
  peer can no longer bypass the limit by dripping one blank line per packet
  (bare-CRLF lines are now counted too).
- Keep the socket passive after an Upgrade / CONNECT is detected until the
  handler accepts, so tunnel bytes are no longer re-parsed as HTTP.
- `recv_capsule/4` now honors the overall timeout across reads and caps the
  partial buffer at 16 MB (`capsule_too_large`).
- Acceptor backs off on unknown accept errors instead of spinning at 100% CPU.

### Fixed

- `wait_connected/1,2` could hang: waiters were stored with a malformed
  reply tag, so `gen_statem:reply` never reached the caller.
- Server stream map leaked one closed-stream entry per keep-alive request;
  streams are now dropped once both directions finish.
- Chunked response framing over a non-chunked `Transfer-Encoding` now
  appends `chunked` to the header so it matches the wire bytes.
- Partial response status line returns `more` instead of `bad_request`.
- Connection policy (keep-alive / close) is resolved before the `request`
  event is emitted, so handlers see consistent state.
- Server loop notifies the handler with `stream_reset` when the connection
  dies mid-stream, preventing an orphaned handler from hanging.
- `stop_server/1` erases the `persistent_term` entry created by
  `start_server/3`.
- `set_active_once` synthesizes a close event when re-arming the socket
  fails, so the connection shuts down promptly instead of stalling.

## [0.2.1] - 2026-04-19

### Fixed

- `h1:upgrade/4` crash when the `:path` pseudo-header is supplied (dead-code
  path in `handle_client_upgrade/4` eagerly encoded pseudo-headers before
  `upgrade_wire/1` stripped them).

## [0.2.0] - 2026-04-19

### Added

- `h1:accept_connect/3,4`: server-side reply of `200 Connection
  Established` to a classic HTTP/1.1 CONNECT with atomic raw-socket
  handoff (RFC 9110 §9.3.6, RFC 9112 §3.2.3). Mirrors
  `h1:accept_upgrade/3` but writes status 200 and injects no
  Connection/Upgrade/framing headers, so bytes past the terminating
  CRLF belong to the tunnel.

## [0.1.1] — 2026-04-19

### Changed

- Hex package name is **`erlang_h1`** (the short `h1` is already taken
  on hex.pm). The OTP application, module atom, and public API are
  unchanged — call sites continue to use `h1:connect/2` etc.

## [0.1.0] — 2026-04-19

Initial release.

### HTTP/1.1 core

- Streaming pure-Erlang parser covering RFC 9110 / RFC 9112: request
  and response lines, chunked transfer, trailers, obs-fold, 100-continue,
  absolute-form / asterisk / authority request targets.
- Request / response / chunk / trailer encoder with CRLF-injection
  guards on header names, methods, paths, and reason phrases.
- RFC 9297 capsule codec (`h1_capsule`) wire-compatible with the
  equivalent module in `erlang_h2`.
- `h1_connection` `gen_statem` running in both client and server modes
  with keep-alive, pipelining (in-order response delivery on the
  server), `Expect: 100-continue`, and Upgrade / 101 Switching
  Protocols with socket handoff.

### Public API

- `h1` module mirrors the surface of `h2` and `quic_h3` so callers can
  swap protocols: `connect`, `request`, `send_data`, `send_trailers`,
  `cancel`, `goaway`, `close`, `start_server`, `stop_server`,
  `send_response`, plus H1-specific `upgrade`, `accept_upgrade`,
  `continue`, `pipeline`.
- Event messages (`{h1, Conn, Event}`) match the `h2` / `h3` shape,
  with an extra `{upgrade, ...}` / `{upgraded, ...}` pair for the
  101 handoff.

### Hardening

- **Smuggling guards (RFC 9112 §6.1).** Reject messages carrying both
  `Content-Length` and `Transfer-Encoding: chunked`; reject differing
  `Content-Length` values across duplicates or in a comma-list; reject
  `Transfer-Encoding` on HTTP/1.0.
- **DoS guards.** Chunk-size hex capped at 16 digits; configurable
  `max_body_size` enforced per stream; idle and request timers armed
  as `gen_statem` timeouts (slowloris guard).
- **Field validation.** Encoder rejects CRLF in header names, methods,
  paths, and reason phrases; parser rejects forbidden fields in
  trailers per RFC 9110 §6.5.1; obs-fold re-validates the unfolded
  value against `max_header_value_size`.
- **Response framing (RFC 9110 §6.3).** HEAD / 1xx / 204 / 304
  responses are body-less regardless of framing headers;
  close-delimited bodies finalise on socket close.
- **TLS defaults.** Client connects with `verify_peer` + OS CA trust +
  hostname check + automatic SNI; user-supplied `ssl_opts` win on
  every key.
- **Host enforcement.** Client auto-adds the `Host:` header from the
  connect hostname; server rejects HTTP/1.1 requests missing `Host`
  with 400 and closes the connection.

### Listener + client integration

- Built-in acceptor pool + listener (`h1_acceptor`, `h1_listener`) and
  per-connection server loop (`h1_server`) that preserves pipelined
  response byte order on the wire (RFC 9112 §9.3).
- Client connect helper (`h1_client`) drives TCP / TLS handshake,
  socket ownership, and `wait_connected` synchronisation.
- Reference `ranch_protocol` module + docs covering drop-in Ranch
  integration and ALPN multiplexing with `h2`.

### Tests

- 52 EUnit tests + 4 PropEr roundtrip properties.
- 149 Common Test cases across parser, encoder, capsule codec,
  connection state machine, end-to-end client/server, Upgrade +
  capsule exchange, Ranch integration, compliance vectors
  (smuggling / framing / chunked / DoS) and interop (curl, plus
  `python:3-alpine` and `nginx:alpine` under Docker).

### Documentation

- `README.md` — install, quickstart, full client & server walkthroughs,
  TLS guidance, tuning, events and error reference, Ranch snippet.
- `docs/features.md` — RFC coverage, in-scope vs. intentionally
  out-of-scope, internal module map.
- `docs/ranch.md` — production-shape protocol module, ALPN multiplex,
  graceful drain, gotchas.

[0.1.0]: https://github.com/benoitc/erlang_h1/releases/tag/0.1.0
[0.1.1]: https://github.com/benoitc/erlang_h1/releases/tag/0.1.1
[0.2.0]: https://github.com/benoitc/erlang_h1/releases/tag/0.2.0
[0.2.1]: https://github.com/benoitc/erlang_h1/releases/tag/0.2.1
[0.2.2]: https://github.com/benoitc/erlang_h1/releases/tag/0.2.2
