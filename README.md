# h1

HTTP/1.1 client and server for Erlang/OTP. Designed so call sites that already use [`h2`](https://github.com/benoitc/erlang_h2) (HTTP/2) or [`quic_h3`](https://github.com/benoitc/erlang_quic) (HTTP/3) can swap protocols without rewrites.

- **RFC 9110 / RFC 9112** messages — chunked transfer, trailers, `Expect: 100-continue`, obs-fold tolerated.
- **RFC 9112 §9.3** request pipelining with in-order response delivery on the wire.
- **RFC 9112 §7** `Upgrade` / **101 Switching Protocols** primitive, including socket handoff.
- **RFC 9110 §9.3.6** `CONNECT` tunnel primitive (`h1:accept_connect/3,4`): 200 Connection Established with atomic raw-socket handoff, no chunked framing.
- **RFC 9297** capsule codec for post-Upgrade framing (wire-compatible with `h2`, shared by [`masque`](https://github.com/benoitc/erlang_masque) for RFC 9298 CONNECT-UDP).
- Hardened against request smuggling (RFC 9112 §6.1), slowloris (idle + request timers), and oversized framing.
- TLS defaults to `verify_peer` with the OS trust store and hostname verification.
- Zero external runtime dependencies; `proper` only in the test profile.

## Contents

- [Install](#install)
- [Quickstart](#quickstart)
- [Client](#client)
- [Server](#server)
- [Upgrade + capsules](#upgrade--capsules)
- [TLS](#tls)
- [Tuning: timeouts, body size, pipelining](#tuning)
- [Events reference](#events-reference)
- [Error reference](#error-reference)
- [Using with Ranch](#using-with-ranch)
- [Modules](#modules)
- [Build and test](#build-and-test)

## Install

The hex package is published as **`erlang_h1`** (the short name `h1`
was already taken on hex.pm). The OTP application and module atom stay
`h1`, so call sites write `h1:connect/2` either way.

```erlang
%% rebar.config — from hex
{deps, [{erlang_h1, "0.2.0"}]}.

%% Or directly from git
{deps, [
    {erlang_h1, {git, "https://github.com/benoitc/erlang_h1.git", {tag, "0.2.0"}}}
]}.
```

Requires **Erlang/OTP 26+**.

The `h1` application owns the top-level supervisor for listeners. Start it from your `*.app.src` dependencies or manually:

```erlang
ok = application:ensure_started(h1).
```

## Quickstart

### One-shot GET

```erlang
ok = application:ensure_started(h1),
{ok, Conn}     = h1:connect("example.com", 80),
{ok, StreamId} = h1:request(Conn, <<"GET">>, <<"/">>, []),
{Status, Body} =
    receive
        {h1, Conn, {response, StreamId, S, _Headers}} ->
            Payload = collect(Conn, StreamId, <<>>),
            {S, Payload}
    end,
ok = h1:close(Conn),
io:format("~p ~p~n", [Status, Body]).

collect(Conn, Id, Acc) ->
    receive
        {h1, Conn, {data, Id, D, false}} -> collect(Conn, Id, <<Acc/binary, D/binary>>);
        {h1, Conn, {data, Id, D, true}}  -> <<Acc/binary, D/binary>>;
        {h1, Conn, {closed, _}}          -> Acc
    end.
```

### A server that echoes "hello"

```erlang
ok = application:ensure_started(h1),
Handler = fun(Conn, Id, <<"GET">>, _Path, _Hs) ->
    h1:send_response(Conn, Id, 200,
                     [{<<"content-type">>, <<"text/plain">>}]),
    h1:send_data(Conn, Id, <<"hello HTTP/1.1">>, true)
end,
{ok, Server} = h1:start_server(8080, #{handler => Handler}),
io:format("listening on ~p~n", [h1:server_port(Server)]).
```

`curl http://127.0.0.1:8080/` returns `hello HTTP/1.1`.

## Client

`h1:connect/2,3` opens a connection. The calling process becomes the *owner*: all protocol events arrive as messages tagged `{h1, Conn, Event}`.

```erlang
-spec h1:connect(Host, Port)       -> {ok, pid()} | {error, term()}.
-spec h1:connect(Host, Port, Opts) -> {ok, pid()} | {error, term()}.
```

`Host` may be a string, binary, or `inet:ip_address()`. `Opts` is a map (see [Tuning](#tuning)); transport defaults to plain TCP.

### Simple GET

```erlang
{ok, Conn}     = h1:connect(<<"httpbin.org">>, 80),
{ok, StreamId} = h1:request(Conn, <<"GET">>, <<"/get">>, []).
```

`Host:` is auto-added from the connect hostname if omitted.

### POST with a known body

```erlang
Body = <<"{\"hello\":\"world\"}">>,
{ok, _} = h1:request(Conn, <<"POST">>, <<"/post">>, [
    {<<"content-type">>, <<"application/json">>}
], Body).
```

`Content-Length` is computed automatically when you pass the body as the 5th argument.

### Streaming an upload

When you don't know the body size up front, use chunked transfer:

```erlang
{ok, Sid} = h1:request(Conn, <<"POST">>, <<"/upload">>, [
    {<<"transfer-encoding">>, <<"chunked">>}
]),
ok = h1:send_data(Conn, Sid, <<"chunk-1 ">>,  false),
ok = h1:send_data(Conn, Sid, <<"chunk-2 ">>,  false),
ok = h1:send_data(Conn, Sid, <<"chunk-3">>,   true).
```

The last call with `EndStream = true` writes the trailing `0\r\n\r\n`.

### Pipelining multiple requests

```erlang
{ok, S1} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
{ok, S2} = h1:request(Conn, <<"GET">>, <<"/b">>, []),
{ok, S3} = h1:request(Conn, <<"GET">>, <<"/c">>, []),
%% Responses arrive in the same order:
{h1, Conn, {response, S1, _, _}} = receive_next(),
{h1, Conn, {response, S2, _, _}} = receive_next(),
{h1, Conn, {response, S3, _, _}} = receive_next().
```

Pass `pipeline => false` in the connect opts if you want explicit serialization — a second `h1:request` while a response is in flight then returns `{error, pipeline_disabled}`.

### Reading trailers

```erlang
{ok, Sid} = h1:request(Conn, <<"GET">>, <<"/chunked-with-trailers">>, []),
loop(Conn, Sid).

loop(Conn, Sid) ->
    receive
        {h1, Conn, {response, Sid, Status, Headers}} ->
            io:format("status=~p~n", [Status]),
            loop(Conn, Sid);
        {h1, Conn, {data, Sid, D, false}} ->
            io:format("chunk: ~p~n", [D]),
            loop(Conn, Sid);
        {h1, Conn, {trailers, Sid, Trailers}} ->
            io:format("trailers: ~p~n", [Trailers]);
        {h1, Conn, {data, Sid, _, true}} ->
            io:format("(no trailers)~n")
    end.
```

`{trailers, Sid, _}` is an implicit end-of-stream, so a chunked response with trailers does not also emit a final `{data, _, _, true}` event.

### 100-continue

Pass `Expect: 100-continue` in the request headers when sending a body:

```erlang
{ok, Sid} = h1:request(Conn, <<"PUT">>, <<"/big">>, [
    {<<"expect">>, <<"100-continue">>},
    {<<"content-length">>, integer_to_binary(byte_size(Body))}
], Body).
```

The client stages the body; it is released onto the wire when a `100 Continue` arrives (surfaced as `{informational, Sid, 100, _}`) or when any non-100 response aborts it.

### HEAD, CONNECT, and other methods

```erlang
{ok, _} = h1:request(Conn, <<"HEAD">>, <<"/big.iso">>, []),
receive
    {h1, Conn, {response, _, _, Hs}} ->
        %% No body follows — the parser honors the HEAD rule even if
        %% Content-Length is present.
        proplists:get_value(<<"content-length">>, Hs)
end.
```

### Closing

```erlang
ok = h1:close(Conn).
```

`close/1` tolerates an already-exited connection (common if the peer closed first), so you don't need to trap exits just to call it.

## Server

`h1:start_server/2,3` opens a listener under the `h1` application's supervisor. The listener owns one listen socket and an acceptor pool; each accepted connection spawns an `h1_server` loop that dispatches requests to your handler.

### Minimal

```erlang
Handler = fun(Conn, Id, Method, Path, _Headers) ->
    Body = iolist_to_binary(io_lib:format("~s ~s", [Method, Path])),
    h1:send_response(Conn, Id, 200,
        [{<<"content-type">>, <<"text/plain">>},
         {<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    h1:send_data(Conn, Id, Body, true)
end,
{ok, Server} = h1:start_server(8080, #{handler => Handler}).
```

### Named server + stop

```erlang
{ok, Server} = h1:start_server(my_http, 8080, #{handler => Handler}),
Port = h1:server_port(Server),
%% later
ok = h1:stop_server(Server).
```

### Handler as a module

```erlang
-module(my_handler).
-export([handle_request/5]).

handle_request(Conn, Id, <<"GET">>, <<"/">>, _Headers) ->
    h1:send_response(Conn, Id, 200, [{<<"content-length">>, <<"2">>}]),
    h1:send_data(Conn, Id, <<"ok">>, true);
handle_request(Conn, Id, _, _, _) ->
    h1:send_response(Conn, Id, 404, [{<<"content-length">>, <<"0">>}]),
    h1:send_data(Conn, Id, <<>>, true).

%% wire it up
{ok, _} = h1:start_server(8080, #{handler => my_handler}).
```

### Reading a request body

Body and trailer events arrive as `{h1_stream, Id, _}` messages in the handler process:

```erlang
echo(Conn, Id, <<"POST">>, _Path, Headers) ->
    Body = collect_body(Id, <<>>),
    Size = integer_to_binary(byte_size(Body)),
    h1:send_response(Conn, Id, 200, [{<<"content-length">>, Size}]),
    h1:send_data(Conn, Id, Body, true).

collect_body(Id, Acc) ->
    receive
        {h1_stream, Id, {data, Bin, true}}  -> <<Acc/binary, Bin/binary>>;
        {h1_stream, Id, {data, Bin, false}} -> collect_body(Id, <<Acc/binary, Bin/binary>>);
        {h1_stream, Id, {trailers, _}}      -> Acc
    end.
```

### Chunked response

When the body length isn't known up front, declare `Transfer-Encoding: chunked` and stream with `send_data/4`:

```erlang
stream(Conn, Id, _Method, _Path, _Headers) ->
    h1:send_response(Conn, Id, 200,
        [{<<"transfer-encoding">>, <<"chunked">>},
         {<<"content-type">>, <<"application/octet-stream">>}]),
    feed_pieces(Conn, Id, 10).

feed_pieces(Conn, Id, 0) ->
    h1:send_data(Conn, Id, <<>>, true);
feed_pieces(Conn, Id, N) ->
    h1:send_data(Conn, Id, integer_to_binary(N), false),
    timer:sleep(50),
    feed_pieces(Conn, Id, N - 1).
```

### Emitting trailers

```erlang
trailers(Conn, Id, _, _, _) ->
    h1:send_response(Conn, Id, 200,
        [{<<"transfer-encoding">>, <<"chunked">>},
         {<<"trailer">>, <<"x-checksum">>}]),
    h1:send_data(Conn, Id, <<"payload">>, false),
    h1:send_trailers(Conn, Id, [{<<"x-checksum">>, <<"deadbeef">>}]).
```

### 100-continue (server side)

When a client sends `Expect: 100-continue`, the handler sees it in the request headers and can decide whether to accept the body:

```erlang
expect_continue(Conn, Id, _, _, Headers) ->
    case proplists:get_value(<<"expect">>, Headers) of
        <<"100-continue">> -> h1:continue(Conn, Id);
        _ -> ok
    end,
    Body = collect_body(Id, <<>>),
    h1:send_response(Conn, Id, 201, [{<<"content-length">>, <<"0">>}]),
    h1:send_data(Conn, Id, <<>>, true).
```

Not calling `h1:continue/2` (and instead sending the final response directly) is also legal — it tells the client to abort the upload.

### Pipelining

`h1_server` spawns one handler process per request but blocks the connection loop until that handler exits before accepting the next request. This guarantees pipelined response bytes are written in order, as required by RFC 9112 §9.3. Handlers still get their own mailbox for body streaming. Scale request-rate by raising `acceptors` (default: one per scheduler).

## Upgrade + capsules

The `Upgrade` / 101 handshake is exposed at the public API. After a successful upgrade the raw socket is transferred to the caller with any leftover bytes the parser had buffered.

### Client initiating an upgrade

```erlang
{ok, Conn} = h1:connect("proxy.example", 443, #{transport => ssl}),
{ok, StreamId, Sock, Buf, RespHeaders} =
    h1:upgrade(Conn, <<"connect-udp">>, [
        {<<"capsule-protocol">>, <<"?1">>}
    ]),
%% From here, Sock is a plain ssl/gen_tcp socket owned by this process.
%% Anything already in Buf was received past the 101 response.
```

### Server accepting an upgrade

The request handler inspects the `Upgrade:` header and calls `accept_upgrade/3` to switch protocols:

```erlang
handle(Conn, Id, <<"GET">>, _Path, Headers) ->
    case proplists:get_value(<<"upgrade">>, Headers) of
        <<"connect-udp">> ->
            {ok, Sock, Buf} = h1:accept_upgrade(Conn, Id,
                [{<<"capsule-protocol">>, <<"?1">>}]),
            masque_loop(Sock, Buf);
        _ ->
            h1:send_response(Conn, Id, 426,
                [{<<"content-length">>, <<"0">>},
                 {<<"upgrade">>, <<"connect-udp">>}]),
            h1:send_data(Conn, Id, <<>>, true)
    end.
```

### RFC 9297 capsule framing on the raw socket

Once you have the post-handoff socket, `h1_upgrade` handles capsule encode/decode:

```erlang
ok = h1_upgrade:send_capsule(gen_tcp, Sock, datagram, <<"udp payload">>),

case h1_upgrade:recv_capsule(gen_tcp, Sock, Buf) of
    {ok, {datagram, Payload}, Rest} ->
        io:format("got datagram ~p~n", [Payload]),
        loop(Sock, Rest);
    {ok, {CustomType, Payload}, Rest} ->
        io:format("capsule type=~p payload=~p~n", [CustomType, Payload]),
        loop(Sock, Rest);
    {error, R} ->
        io:format("capsule decode error: ~p~n", [R])
end.
```

`h1_upgrade` is protocol-agnostic — it doesn't know about `connect-udp`, `connect-ip`, or any specific capsule type. Consumers like `masque` layer their own semantics on top.

## TLS

### Client connecting to a trusted server

Defaults are safe — `{verify, verify_peer}`, OS trust store via `public_key:cacerts_get/0`, hostname verification, and SNI driven by the connect hostname.

```erlang
{ok, Conn} = h1:connect("api.example", 443, #{transport => ssl}).
```

### Client connecting to a self-signed or private server

User-supplied `ssl_opts` win on every key, so override whatever you need:

```erlang
{ok, Conn} = h1:connect("localhost", 8443, #{
    transport => ssl,
    ssl_opts  => [{verify, verify_none}]
}).
```

Or pin a specific CA chain:

```erlang
{ok, Conn} = h1:connect("internal.corp", 443, #{
    transport => ssl,
    ssl_opts  => [{cacertfile, "/etc/ca/internal-bundle.pem"}]
}).
```

### Server with a certificate

```erlang
{ok, Server} = h1:start_server(8443, #{
    transport => ssl,
    cert      => "server.pem",
    key       => "server-key.pem",
    handler   => Handler
}).
```

`cert` and `key` accept either file paths (as string or binary). The acceptor pool does `transport_accept` only; the TLS handshake itself runs in the per-connection process so one slow handshake never blocks the accept queue. Override `handshake_timeout` (default 30 s) in the server opts.

## Tuning

### Connect and server opts

```erlang
%% h1:connect/3 opts (all optional except where noted)
#{transport              => tcp | ssl,                 %% default: tcp
  ssl_opts               => [ssl:tls_client_option()], %% merged over safe defaults
  connect_timeout        => timeout(),                 %% default: 30_000
  timeout                => timeout(),                 %% wait_connected timeout, default 30_000
  pipeline               => boolean(),                 %% default: true
  max_keepalive_requests => pos_integer(),             %% default: 100
  idle_timeout           => timeout() | infinity,      %% default: 300_000 (5 min)
  request_timeout        => timeout() | infinity,      %% default: 60_000
  max_body_size          => pos_integer() | infinity}. %% default: 8_388_608 (8 MB)

%% h1:start_server/2,3 opts
#{transport              => tcp | ssl,                 %% default: tcp
  cert                   => binary() | string(),       %% required for ssl
  key                    => binary() | string(),       %% required for ssl
  cacerts                => [binary()],
  handler                := fun(...) | module(),       %% required
  acceptors              => pos_integer(),             %% default: erlang:system_info(schedulers)
  handshake_timeout      => timeout(),                 %% default: 30_000
  idle_timeout           => timeout() | infinity,
  request_timeout        => timeout() | infinity,
  max_keepalive_requests => pos_integer(),
  max_body_size          => pos_integer() | infinity}.
```

### Timeouts and slowloris

`idle_timeout` re-arms on every byte over the connection; it only fires when the peer stops talking entirely. `request_timeout` is armed while a request is in flight (from send-request on the client / from header receipt on the server) and cleared when the response completes. Either firing stops the connection with `{shutdown, idle_timeout}` / `{shutdown, request_timeout}`.

Pass `infinity` to disable.

### Body size cap

`max_body_size` (default 8 MB) bounds `Content-Length` and chunked body accumulation per stream. Exceeding it causes the parser to return `{error, body_too_large}` and the connection to shut. Set to `infinity` if you truly want unbounded uploads, but prefer a per-route enforcement when possible.

### Header and URI limits

Inherited from the parser record in `include/h1.hrl`:

- `max_line_length` — 16 KiB
- `max_header_name_size` — 256 bytes
- `max_header_value_size` — 8 KiB
- `max_headers` — 100

All are parser options you can override via the connect/server opts map.

## Events reference

Messages delivered to the owner (connect caller on the client side; `h1_server` process on the server side — which in turn forwards `{h1_stream, …}` messages to the request handler):

| Message | When | Arguments |
|---|---|---|
| `{h1, Conn, connected}` | socket ready, parser active | — |
| `{h1, Conn, {request,       Id, Method, Path, Headers}}` | server mode: peer sent a request | |
| `{h1, Conn, {response,      Id, Status, Headers}}` | client mode: final response headers (2xx–5xx) | |
| `{h1, Conn, {informational, Id, Status, Headers}}` | 1xx interim (100 Continue / 103 / …) | |
| `{h1, Conn, {data,          Id, Data, EndStream}}` | body fragment | `EndStream :: boolean()` |
| `{h1, Conn, {trailers,      Id, Headers}}` | chunked body trailers; implies end-of-stream | |
| `{h1, Conn, {upgrade,       Id, Proto, Method, Path, Headers}}` | server: peer requested Upgrade | |
| `{h1, Conn, {upgraded,      Id, Proto, Socket, Buffer, Headers}}` | after 101 handoff | |
| `{h1, Conn, {stream_reset,  Id, Reason}}` | stream cancelled | |
| `{h1, Conn, {goaway,        LastId, Reason}}` | peer signaled shutdown | |
| `{h1, Conn, {closed,        Reason}}` | connection closed | |

Inside a server handler process, the per-stream events are re-routed:

| Message | Meaning |
|---|---|
| `{h1_stream, Id, {data, Data, EndStream}}` | body fragment for request `Id` |
| `{h1_stream, Id, {trailers, Trailers}}` | trailers for request `Id` |
| `{h1_stream, Id, {stream_reset, Reason}}` | client aborted mid-stream |

## Error reference

Failures return `{error, Reason}` from API calls or appear as `{closed, Reason}` / `{shutdown, Reason}` when the connection stops. Highlights:

| Reason | Meaning |
|---|---|
| `conflicting_framing` | `Content-Length` and `Transfer-Encoding: chunked` on the same message (RFC 9112 §6.1 smuggling guard) |
| `conflicting_content_length` | differing `Content-Length` values across duplicates or in a comma-list |
| `te_on_http_1_0` | `Transfer-Encoding` on an HTTP/1.0 message (not permitted) |
| `chunk_size_too_long` | chunk-size hex digits exceeded the 16-digit cap (DoS guard) |
| `body_too_large` | body exceeded `max_body_size` |
| `forbidden_trailer` | a trailer tried to carry a forbidden field (`Content-Length`, `Host`, etc.) |
| `too_many_headers` | header count exceeded `max_headers` |
| `header_name_too_long` / `header_value_too_long` | field size over limit |
| `method_too_long` / `uri_too_long` / `line_too_long` | request-line piece over limit |
| `bad_request` | malformed request line, status line, or version |
| `idle_timeout` / `request_timeout` | connection/request was silent past its cap |
| `pipeline_disabled` | `pipeline => false` and a prior request was still in flight |

## Using with Ranch

`h1:start_server/2` runs its own acceptor pool. To plug into Ranch instead, hand the socket straight to `h1_connection`:

```erlang
-module(h1_ranch_protocol).
-behaviour(ranch_protocol).
-export([start_link/3]).

start_link(Ref, Transport, Opts) ->
    {ok, spawn_link(fun() -> init(Ref, Transport, Opts) end)}.

init(Ref, Transport, #{handler := Handler}) ->
    {ok, Socket}  = ranch:handshake(Ref),
    TransportMod  = case Transport of ranch_ssl -> ssl; ranch_tcp -> gen_tcp end,
    {ok, Conn}    = h1_connection:start_link(server, Socket, self(), #{}),
    ok            = TransportMod:controlling_process(Socket, Conn),
    _             = h1_connection:activate(Conn),
    server_loop(Conn, Handler).

server_loop(Conn, Handler) ->
    receive
        {h1, Conn, {request, Id, M, P, H}} ->
            Handler(Conn, Id, M, P, H),
            server_loop(Conn, Handler);
        {h1, Conn, {closed, _}} -> ok;
        _ -> server_loop(Conn, Handler)
    end.
```

Register it as a Ranch protocol:

```erlang
{ok, _} = ranch:start_listener(my_h1, ranch_tcp,
    #{socket_opts => [{port, 8080}]},
    h1_ranch_protocol,
    #{handler => fun my_handler:handle/5}).
```

Ranch owns draining, acceptor-pool sizing, and metrics; `h1_connection` handles HTTP/1.1 semantics.

For a production-shaped protocol module (per-request handler supervision, pipeline ordering, Upgrade passthrough, TLS ALPN multiplexing of `h1` + `h2` on one port, graceful drain) see [docs/ranch.md](docs/ranch.md).

## Modules

| Module | Purpose |
|---|---|
| `h1` | Public API (client + server). |
| `h1_connection` | `gen_statem` per-connection state machine. |
| `h1_client` | Client-side connect + handshake + TLS defaults. |
| `h1_server` | Per-connection server loop, handler dispatch. |
| `h1_listener` | Owns the listen socket + acceptor pool. |
| `h1_acceptor` | Bare `accept/1` loop; TLS handshake in the connection. |
| `h1_upgrade` | RFC 9297 capsule send/recv helpers on the post-handoff socket. |
| `h1_parse` / `h1_parse_erl` | Streaming request/response parser. |
| `h1_message` | Request/response/chunk/trailer encoder. |
| `h1_capsule` / `h1_varint` | RFC 9297 capsule codec. |
| `h1_error` | Reason-code mappings. |

## Build and test

```bash
rebar3 compile
rebar3 eunit          # 52 tests + 4 PropEr roundtrip properties
rebar3 ct             # 157 CT cases across parse / message / capsule / connection
                      # / e2e / upgrade / connect / interop / compliance
rebar3 dialyzer       # clean
rebar3 ex_doc         # HTML docs under doc/
```

### Interop suite

`test/h1_interop_SUITE.erl` drives our server with `curl` (GET / POST / HEAD / chunked) and our client against `nginx:alpine` and `python:3-alpine` running under Docker. Each case probes for `docker` / `curl` on the host and skips cleanly when absent, so the suite stays green on CI without those tools:

```bash
rebar3 ct --suite=test/h1_interop_SUITE
```

### Compliance suite

`test/h1_compliance_SUITE.erl` codifies RFC 9110 / RFC 9112 vectors (smuggling, chunked, field syntax, request-target forms, body-framing rules, DoS guards) as static fixtures. Curated from RFC worked examples, [PortSwigger's HTTP Desync corpus](https://portswigger.net/research/http-desync-attacks-request-smuggling-reborn), and the [http-garden](https://github.com/narfindustries/http-garden) differential-testing project.

```bash
rebar3 ct --suite=test/h1_compliance_SUITE
```

## Status

Useful for embedding HTTP/1.1 into Erlang applications that also want the h2 / h3 event surface. Intentionally out of scope:

- HTTP/0.9.
- `Upgrade: h2c` cleartext negotiation (deprecated by RFC 9113); use ALPN with `h2` directly instead.
- Proxy-specific semantics beyond the `Upgrade` and `CONNECT 200` primitives (upstream routing, forward-proxy ACLs, `Proxy-Authorization`). `accept_upgrade` and `accept_connect` hand the socket off; the rest belongs in the proxy library. WebSocket / `h2c`-over-Upgrade framing is explicitly out of scope.

See `docs/features.md` for the full RFC coverage + gap list.

## License

Apache License 2.0
