# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions
follow [Semantic Versioning](https://semver.org/).

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
