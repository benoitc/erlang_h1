# Features

`h1` implements HTTP/1.1 as a client and a server on top of Erlang/OTP sockets. This page lists what is supported, what is intentionally left out, and the internal modules a library user may want to know about.

## Supported

### Messages (RFC 9110 / RFC 9112)

- Request and response parsing in one pure-Erlang streaming parser (`h1_parse_erl`). Dual-mode: the same code path handles a request or a response line.
- Header names are normalised to lowercase on emit so plain `proplists:get_value(<<"content-length">>, Headers)` just works (and matches the h2-on-the-wire rule).
- Obs-fold (`\r\n<WS>`) tolerated and rewritten to a single space.
- `Content-Length` and `Transfer-Encoding: chunked` both supported on the framing selection path; caller may pass either explicitly, or let `h1_message:choose_framing/2` pick one based on body shape.
- **Smuggling guard (§6.1):** a message carrying both `Content-Length` and `Transfer-Encoding` is rejected with `{error, conflicting_framing}`. No silent strip.
- Multiple `Content-Length` values — whether supplied as separate headers or as a comma-list `5, 7` — are coalesced only when every value parses to the same non-negative integer; any mismatch becomes `{error, conflicting_content_length}`. Unparseable values become `{error, bad_request}`.
- HTTP/1.0 senders using `Transfer-Encoding` are rejected with `{error, te_on_http_1_0}` — RFC 9112 §6.1 forbids TE on 1.0 and accepting it creates a smuggling surface with downstream proxies.
- Chunked body with chunk extensions (`5;ext=1\r\n…`) tolerated — extensions parsed and discarded.
- Trailers after the final `0\r\n` chunk surfaced as a distinct `{trailers, StreamId, Headers}` event and treated as end-of-stream. Fields forbidden in trailers by RFC 9110 §6.5.1 (`Content-Length`, `Transfer-Encoding`, `Host`, framing/auth headers, etc.) are rejected with `{error, forbidden_trailer}`.
- Response body framing follows RFC 9112 §6.3: HEAD / 1xx / 204 / 304 responses carry no body even if `Content-Length` is present; `Content-Length` wins over close-delimited otherwise; a response with neither `Content-Length` nor `Transfer-Encoding` is treated as close-delimited (body extends to socket close, and the connection driver calls `h1_parse_erl:finish/1` on `tcp_closed`/`ssl_closed` to emit the final end-of-stream event).
- Limits enforced with `{error, Reason}` rather than silent truncation: `method_too_long`, `uri_too_long`, `header_name_too_long`, `header_value_too_long`, `too_many_headers`, `chunk_size_too_long` (chunk-size line capped at 16 hex digits — DoS guard), `body_too_large` (per `max_body_size` parser option; default `?H1_MAX_BODY_SIZE` = 8 MB, pass `infinity` to disable).
- Tolerance knobs (parser options): `max_line_length`, `max_empty_lines`, `max_header_name_size`, `max_header_value_size`, `max_headers`, `max_body_size`. Obs-fold is accepted then re-validated against `max_header_value_size` to prevent a folded value from sneaking past the limit.

### Connection state machine

`h1_connection` is a single `gen_statem` used in both client and server mode.

- **Idle and request timers (slowloris guard):** `idle_timeout` (default 5 min) re-armed on every byte, and `request_timeout` (default 60 s) armed while a request is in flight. Either timer firing stops the connection with `{shutdown, idle_timeout}` / `{shutdown, request_timeout}`. Pass `infinity` to disable.
- **Pipelining flag (`pipeline`):** defaults to `true`. When set to `false`, a client's second `h1:request/*` call while a prior response is still in flight returns `{error, pipeline_disabled}` instead of queueing.
- **Host auto-add (client):** if the caller didn't include a `host:` header, the client adds one from the hostname passed to `h1:connect/*`. HTTP/1.1 requests reaching the server without a `Host` header are answered with 400 and the connection is closed — RFC 9110 §7.2 requires exactly one `Host`.
- Keep-alive (RFC 9112 §9.3): HTTP/1.1 default is reuse; `Connection: close` from either side flips the connection to `close_after = true` and shuts after the current exchange drains.
- **Request pipelining** (client): multiple `h1:request/4,5` calls may be in flight simultaneously; responses are attached to requests in the order they were sent. Each request gets a monotonic `StreamId` so the event shape matches h2.
- **Pipelined response ordering** (server): `h1_server:connection_loop/2` only pulls the next `{request, ...}` event from the mailbox after the current handler process exits, so response bytes for request N are fully flushed before any bytes for request N+1 hit the socket.
- `Expect: 100-continue` (RFC 9110 §10.1.1):
  - Server surfaces it as a stream flag; the handler calls `h1:continue/2` to send `100 Continue` or ignores it and sends the final response directly.
  - Client sets the header automatically when the caller supplies a body, stages the body, and releases it on receiving `100 Continue` or a non-100 response.
- Trailers on chunked messages: `h1:send_trailers/3` writes the final `0\r\n<trailers>\r\n\r\n` block.
- Owner monitoring: when the owner process exits, the connection stops with `{shutdown, owner_down}`.
- `controlling_process/2` transfers ownership; `set_stream_handler/3,4` routes per-stream events to a different pid (body streaming to a worker).
- `close/1` tolerates any already-exited state (noproc, `{shutdown, peer_closed}`, etc.) so the caller does not need to trap.

### Upgrade / 101 Switching Protocols (RFC 9112 §7.8)

- Client: `h1:upgrade/3,4` writes a GET with `Connection: Upgrade` + `Upgrade: <token>`, blocks until either a 101 arrives (returning `{ok, StreamId, Socket, Buffer, Headers}`) or a non-101 response aborts it.
- Server: parser detects `Upgrade:` + `Connection: upgrade`, emits `{upgrade, StreamId, Proto, Method, Path, Headers}`, then pauses the socket so no bytes past the request are consumed. The handler calls `h1:accept_upgrade/3` to send the 101 and receive `{ok, Socket, Buffer}`.
- On either side, after a successful 101 the `gen_statem` stops with `{shutdown, upgraded}` and the socket is `controlling_process`'d to the caller, along with any leftover buffered bytes.
- `h1_upgrade` provides framing-agnostic capsule send / recv helpers on the handed-back socket for consumers (e.g. `masque` for RFC 9298 CONNECT-UDP).

### CONNECT tunnels (RFC 9110 §9.3.6, RFC 9112 §3.2.3)

- Classic HTTP/1.1 `CONNECT authority HTTP/1.1` requests reach the server as a regular `{request, StreamId, <<"CONNECT">>, Authority, Headers}` event. The request target is in authority-form (`host:port` or `[ipv6]:port`) and is surfaced verbatim in `Path`.
- Server handler replies with `h1:accept_connect/3,4`. The helper writes `HTTP/1.1 200 Connection Established\r\n` plus caller-supplied headers plus the terminating CRLF directly, then atomically hands the raw socket off to the caller. Return shape: `{ok, Transport, Socket, Buffer}` where `Transport` is `gen_tcp` or `ssl` and `Buffer` is any bytes the parser had already read past the request.
- No `Connection: Upgrade` / `Upgrade:` / `Transfer-Encoding: chunked` headers are injected: bytes past the blank line belong to the tunnel, not to an HTTP response body. Sequencing `send_response/4` + a separate handoff would be wrong because `send_response/4` defaults to chunked framing when no `Content-Length` is set.
- After a successful `accept_connect`, the `gen_statem` stops with `{shutdown, connected}` and leaves the socket open (owned by the caller). The owner also receives `{h1, Conn, {connected, StreamId, Transport, Socket, Buffer}}`.
- Error returns: `{error, unknown_stream}` (bogus StreamId), `{error, response_already_sent}` (after `h1:send_response/4` on the same stream), `{error, Reason}` from the underlying `send`.
- Counterpart to `accept_upgrade/3` for the 101 Switching Protocols case. Downstream use: `erlang_masque`'s HTTP/1.1 CONNECT-TCP fallback.

### Capsules (RFC 9297)

- `h1_capsule:encode/2` and `h1_capsule:decode/1` implement the `Capsule-Protocol` wire format (varint type + varint length + payload).
- `h1_varint` is a copy of the QUIC varint codec (1/2/4/8-byte forms).
- `h1_upgrade:send_capsule/4` / `recv_capsule/3,4` wrap these for `gen_tcp` and `ssl` sockets, keeping a caller-provided buffer so partial reads never drop bytes.
- Wire-compatible with `h2_capsule` in [erlang_h2](https://github.com/benoitc/erlang_h2); the two modules exist as separate copies to avoid a cross-library runtime dependency.

### API surface

Public module `h1`:

```erlang
%% Client
h1:connect/2,3
h1:wait_connected/1,2
h1:request/2,3,4,5
h1:send_data/3,4
h1:send_trailers/3
h1:cancel/2,3
h1:cancel_stream/2,3
h1:set_stream_handler/3,4
h1:unset_stream_handler/2
h1:goaway/1,2
h1:close/1
h1:controlling_process/2

%% Server
h1:start_server/2,3
h1:stop_server/1
h1:server_port/1
h1:send_response/4

%% HTTP/1.1-specific
h1:upgrade/3,4
h1:accept_upgrade/3
h1:accept_connect/3,4
h1:continue/2
h1:pipeline/2

%% Inspection
h1:get_settings/1
h1:get_peer_settings/1
```

The export list mirrors `h2` and `quic_h3` where semantics overlap. H1-specific primitives (`upgrade`, `accept_upgrade`, `continue`, `pipeline`) cover what h2 and h3 have no equivalent of.

### Events to the owner process

```erlang
{h1, Conn, connected}
{h1, Conn, {request,       StreamId, Method, Path, Headers}}       %% server mode
{h1, Conn, {response,      StreamId, Status, Headers}}             %% client mode
{h1, Conn, {informational, StreamId, Status, Headers}}             %% 1xx interim
{h1, Conn, {data,          StreamId, Data, EndStream}}
{h1, Conn, {trailers,      StreamId, Headers}}
{h1, Conn, {upgrade,       StreamId, Proto, Method, Path, Headers}} %% server: peer asked for Upgrade
{h1, Conn, {upgraded,      StreamId, Proto, Socket, Buffer, Headers}} %% after 101
{h1, Conn, {connected,     StreamId, Transport, Socket, Buffer}}     %% after CONNECT 200
{h1, Conn, {stream_reset,  StreamId, Reason}}
{h1, Conn, {goaway,        LastStreamId, Reason}}
{h1, Conn, {closed,        Reason}}
```

Identical shape to `h2` and `quic_h3` except for `upgrade` / `upgraded` (H1-only). Per-stream events (`data`, `trailers`, `stream_reset`) route to the pid registered via `h1:set_stream_handler/3,4` if set, otherwise to the connection owner.

Inside the server, `h1_server` re-routes `{h1, Conn, {data, …}}` / `{trailers, …}` as `{h1_stream, StreamId, …}` messages to the spawned handler process — the same shape body handlers use to collect POST / chunked uploads.

### TLS

- Advertised via `{alpn_advertised_protocols, [<<"http/1.1">>]}` on the client and `{alpn_preferred_protocols, [<<"http/1.1">>]}` on the server listen socket.
- TLS handshake is deferred to the connection process (not blocking the acceptor).
- **Client defaults:** `{verify, verify_peer}` plus OS trust store via `public_key:cacerts_get/0` plus hostname verification via `public_key:pkix_verify_hostname_match_fun(https)`. SNI is set automatically when the connect host is a DNS name (not an IP literal). Callers that explicitly pass `ssl_opts` can opt out of any of these — the user list wins on every key.

## Intentionally out of scope

- **HTTP/0.9.** Not parsed, not generated.
- **`Upgrade: h2c`** cleartext negotiation to HTTP/2 — deprecated by RFC 9113. Use ALPN with `h2` (or `h2c` via prior knowledge) in the `h2` library instead.
- **Server push**, ETag / caching policy, content coding (`gzip`, `br`, …). The library ships the messages as-is; compression is a caller concern.
- **Proxy-specific semantics** beyond the `Upgrade` and `CONNECT 200` primitives (routing to upstream hosts, forward-proxy ACLs, `Proxy-Authorization` handling). The `accept_upgrade` and `accept_connect` helpers give downstream libraries (`masque`, custom forward proxies) the socket after a successful handshake; everything beyond that belongs in the proxy library.
- **WebSocket framing** on top of an Upgraded connection — `Upgrade: websocket` is parsed and the handshake is exposed, but the `ws` frame layer is out of scope here. Layer it on top of the handed-back socket with a dedicated library.

## Internal modules

| Module | Role |
|---|---|
| `h1` | Public API (client + server). |
| `h1_connection` | `gen_statem` owning the socket; one process per connection. |
| `h1_app` / `h1_sup` | Application callback and top-level supervisor (`simple_one_for_one` parent of listeners). |
| `h1_listener` | Per-server process: owns the listen socket and the acceptor pool. |
| `h1_acceptor` | Bare `accept/1` loop. Spawns an `h1_server` per accepted socket. |
| `h1_server` | Per-connection loop: spawns one handler process per request, serialises requests for pipelined response order. |
| `h1_client` | Client-side connect + socket handoff to `h1_connection`. |
| `h1_parse` / `h1_parse_erl` | Streaming request/response parser with chunked + trailer support. |
| `h1_message` | Request/response/chunk/trailer encoder, framing selection. |
| `h1_upgrade` | RFC 9297 capsule helpers on the post-handoff raw socket. |
| `h1_capsule` / `h1_varint` | RFC 9297 wire format. |
| `h1_error` | Reason-code mappings. |

## Testing

- `rebar3 eunit` — 52 EUnit tests plus 4 PropEr roundtrip properties.
- `rebar3 ct --suite=test/h1_parse_SUITE` — 24 streaming-parser cases (request, response, chunked, trailers, limits).
- `rebar3 ct --suite=test/h1_message_SUITE` — 12 encoder cases.
- `rebar3 ct --suite=test/h1_capsule_SUITE` — 9 capsule encode/decode cases.
- `rebar3 ct --suite=test/h1_connection_SUITE` — 13 loopback `gen_statem` cases: GET / POST / chunked / trailers / keep-alive / pipelining / Expect / Upgrade / capsule exchange.
- `rebar3 ct --suite=test/h1_e2e_SUITE` — 8 cases through the public API over real TCP + TLS.
- `rebar3 ct --suite=test/h1_upgrade_SUITE` — 3 end-to-end upgrade cases with capsule framing.
- `rebar3 ct --suite=test/h1_connect_SUITE` — 8 end-to-end CONNECT cases (authority-form targets, IPv6, ExtraHeaders round-trip, no-chunked-framing probe, socket ownership after handoff, `{shutdown, connected}` termination, error paths).
- `rebar3 ct --suite=test/h1_interop_SUITE` — curl / python3 / nginx probes, skipped when the binary is absent.
- `rebar3 dialyzer` — clean.
