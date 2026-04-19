# h1

HTTP/1.1 client and server for Erlang/OTP.

- **RFC 9110 / RFC 9112** messages, chunked transfer, trailers, and `Expect: 100-continue` handling.
- Request pipelining (RFC 9112 §9.3) with in-order response delivery.
- **RFC 9112 §7** `Upgrade` / **101 Switching Protocols** primitive, socket handoff included.
- **RFC 9297** capsule codec for post-Upgrade framing (wire-compatible with [`h2`](https://github.com/benoitc/erlang_h2), shared by [`masque`](https://github.com/benoitc/erlang_masque) for RFC 9298 CONNECT-UDP).
- Owner-process event messages (`{h1, Conn, Event}`) and a public API that mirror [`h2`](https://github.com/benoitc/erlang_h2) and [`quic_h3`](https://github.com/benoitc/erlang_quic) so applications can swap transports without rewriting call sites.
- Zero external runtime dependencies; `proper` only in the test profile.

## Install

Add to `rebar.config`:

```erlang
{deps, [
    {h1, "0.1.0", {git, "https://github.com/benoitc/erlang_h1.git", {tag, "0.1.0"}}}
]}.
```

Requires Erlang/OTP 26+.

## Client

```erlang
{ok, Conn}    = h1:connect("example.com", 80),
{ok, StreamId} = h1:request(Conn, <<"GET">>, <<"/">>,
                            [{<<"host">>, <<"example.com">>}]),
receive
    {h1, Conn, {response, StreamId, Status, _Headers}} ->
        io:format("status: ~p~n", [Status])
end,
receive
    {h1, Conn, {data, StreamId, Body, true}} ->
        io:format("body: ~p~n", [Body])
end,
ok = h1:close(Conn).
```

Messages delivered to the owner process:

| Message | Meaning |
|---|---|
| `{h1, Conn, connected}` | socket ready, parser active |
| `{h1, Conn, {response, StreamId, Status, Headers}}` | final response headers (2xx–5xx) |
| `{h1, Conn, {informational, StreamId, Status, Headers}}` | 1xx interim response (100 Continue / 103 / …) |
| `{h1, Conn, {data, StreamId, Data, EndStream}}` | body fragment (empty final frame marks end-of-stream) |
| `{h1, Conn, {trailers, StreamId, Headers}}` | trailers (end-of-stream implied) |
| `{h1, Conn, {upgraded, StreamId, Proto, Socket, Buffer, Headers}}` | 101 Switching Protocols; socket is handed back to the caller |
| `{h1, Conn, {stream_reset, StreamId, Reason}}` | stream cancelled |
| `{h1, Conn, {goaway, LastStreamId, Reason}}` | peer signaled shutdown (`Connection: close`) |
| `{h1, Conn, {closed, Reason}}` | connection closed |

Options to `h1:connect/3`:

```erlang
#{transport               => tcp | ssl,       %% default: tcp
  ssl_opts                => [ssl:tls_client_option()],
  connect_timeout         => timeout(),
  timeout                 => timeout(),
  pipeline                => boolean(),        %% default: true
  max_keepalive_requests  => pos_integer(),    %% default: 100
  idle_timeout            => timeout(),
  request_timeout         => timeout(),
  max_body_size           => pos_integer() | infinity}  %% default: 8 MB
```

TLS defaults to `{verify, verify_peer}` with the OS trust store and strict hostname verification. To connect to a self-signed server, pass `ssl_opts => [{verify, verify_none}]` explicitly — user-supplied options win on every key.

Send a request with a body:

```erlang
{ok, Sid} = h1:request(Conn, <<"POST">>, <<"/upload">>, Headers, Body).
```

Or stream it in chunks:

```erlang
{ok, Sid} = h1:request(Conn, <<"POST">>, <<"/upload">>, Headers),
ok = h1:send_data(Conn, Sid, Chunk1, false),
ok = h1:send_data(Conn, Sid, Chunk2, true).
```

## Server

`h1:start_server/2` starts a listener under the `h1` application's supervision tree, so start the application first:

```erlang
ok = application:ensure_started(h1).
```

```erlang
Handler = fun(Conn, StreamId, <<"GET">>, <<"/">>, _Headers) ->
    h1:send_response(Conn, StreamId, 200,
                     [{<<"content-type">>, <<"text/plain">>}]),
    h1:send_data(Conn, StreamId, <<"Hello HTTP/1.1!">>, true)
end,

{ok, Server} = h1:start_server(8080, #{
    transport => tcp,
    handler   => Handler
}),

Port = h1:server_port(Server),
%% ... later ...
ok = h1:stop_server(Server).
```

Options to `h1:start_server/2,3`:

```erlang
#{transport               => tcp | ssl,        %% default: tcp
  cert                    => binary() | string(),  %% required for ssl
  key                     => binary() | string(),  %% required for ssl
  cacerts                 => [binary()],
  handler                 := fun((Conn, Id, Method, Path, Headers) -> any()),
  acceptors               => pos_integer(),    %% default: schedulers
  handshake_timeout       => timeout(),
  idle_timeout            => timeout(),
  request_timeout         => timeout(),
  max_keepalive_requests  => pos_integer()}
```

A module handler is also supported — `Mod:handle_request/5` receives the same arguments.

Body and trailers arrive as messages in the handler process:

```erlang
fun(Conn, Id, <<"POST">>, _Path, _Hs) ->
    Body = collect_body(Id, <<>>),
    h1:send_response(Conn, Id, 200, [{<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    h1:send_data(Conn, Id, Body, true)
end,

collect_body(Id, Acc) ->
    receive
        {h1_stream, Id, {data, Bin, true}}  -> <<Acc/binary, Bin/binary>>;
        {h1_stream, Id, {data, Bin, false}} -> collect_body(Id, <<Acc/binary, Bin/binary>>);
        {h1_stream, Id, {trailers, _}}      -> Acc
    end.
```

### Pipelining and request order

`h1_server` processes one request at a time per connection — the next `{request, ...}` event is not pulled from the mailbox until the current handler exits. This keeps pipelined response bytes in order on the wire, as required by RFC 9112 §9.3, even though handlers are spawned so their mailboxes stay independent. Raise `acceptors` if connection-rate is your bottleneck; per-connection concurrency is fixed by the protocol.

## Upgrade + capsules

Open a tunnel with `h1:upgrade/3,4`:

```erlang
{ok, Conn}                  = h1:connect(Host, Port),
{ok, _Id, Sock, Buf, _Hdrs} = h1:upgrade(Conn, <<"connect-udp">>, Headers).
%% `Sock' is a raw gen_tcp/ssl socket now owned by the caller;
%% `Buf' is any bytes the parser had buffered past the 101 response.
```

Server side, from the request handler:

```erlang
fun(Conn, Id, <<"GET">>, _Path, Headers) ->
    case proplists:get_value(<<"upgrade">>, Headers) of
        <<"connect-udp">> ->
            {ok, Sock, Buf} = h1:accept_upgrade(Conn, Id, []),
            masque_serve(Sock, Buf);
        _ ->
            h1:send_response(Conn, Id, 400, [{<<"content-length">>, <<"0">>}]),
            h1:send_data(Conn, Id, <<>>, true)
    end
end.
```

`h1_upgrade` provides capsule framing over the post-handoff socket:

```erlang
ok                          = h1_upgrade:send_capsule(gen_tcp, Sock, datagram, <<"payload">>),
{ok, {datagram, In}, NewBuf} = h1_upgrade:recv_capsule(gen_tcp, Sock, Buf, 5000).
```

The module knows nothing about `connect-udp`, `connect-ip`, or any other protocol token — it only frames and reads RFC 9297 capsules. Consumers like `masque` layer their own semantics on top.

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

## Modules

| Module | Purpose |
|---|---|
| `h1` | Public API (client + server). |
| `h1_connection` | `gen_statem` per-connection state machine. |
| `h1_client` | Client-side connect + handshake. |
| `h1_server` | Per-connection server loop (handler dispatch). |
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
rebar3 ct             # 74 CT cases across parse / message / capsule / connection / e2e / upgrade / interop
rebar3 dialyzer       # clean
```

## Interop

`test/h1_interop_SUITE.erl` exercises our server with `curl` (GET / POST / HEAD / chunked) and our client against `python3 -m http.server` and `nginx`. Each probe uses `os:find_executable/1` and skips when the binary is missing, so the suite stays green on CI without the tool:

```bash
rebar3 ct --suite=test/h1_interop_SUITE
```

## Status

Useful for embedding HTTP/1.1 into Erlang applications that also want the h2 / h3 event surface. Intentionally out of scope:

- HTTP/0.9.
- `Upgrade: h2c` cleartext negotiation (deprecated by RFC 9113); use ALPN with `h2` directly instead.
- Proxy-specific semantics (forward proxy, CONNECT to arbitrary hosts) — the `Upgrade` primitive is enough for `masque` and the WebSocket / `h2c`-over-Upgrade dance is explicitly not supported.

See `docs/features.md` for the full RFC coverage + gap list.

## License

Apache License 2.0
