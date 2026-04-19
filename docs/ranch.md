# Using h1 with Ranch

[Ranch](https://github.com/ninenines/ranch) is the de-facto acceptor pool / connection supervisor for Erlang. If your application already uses Ranch (for example, because Cowboy runs HTTP/2 / WebSockets on the same port, or because you want Ranch's draining and metrics), plug `h1_connection` directly into a Ranch protocol module — Ranch owns the listen socket, you own HTTP/1.1 semantics.

This document walks through the pieces: the minimal protocol module, how `h1_connection` takes over the socket, a production-shaped version with configurable handlers and TLS, and how to multiplex `h1` and `h2` on the same TLS listener via ALPN.

## Contents

- [When to use Ranch over h1:start_server](#when-to-use-ranch-over-h1start_server)
- [Dependencies](#dependencies)
- [The minimal protocol](#the-minimal-protocol)
- [How the socket handoff works](#how-the-socket-handoff-works)
- [A production-shaped protocol](#a-production-shaped-protocol)
- [Starting the listener](#starting-the-listener)
- [Handling request bodies concurrently](#handling-request-bodies-concurrently)
- [Handling Upgrade through Ranch](#handling-upgrade-through-ranch)
- [ALPN: h1 and h2 on the same port](#alpn-h1-and-h2-on-the-same-port)
- [Graceful shutdown](#graceful-shutdown)
- [Gotchas](#gotchas)

## When to use Ranch over h1:start_server

`h1:start_server/2,3` is a perfectly good listener — it opens a listen socket, runs an acceptor pool, spawns per-connection state machines. Reach for Ranch when:

- You already have a Ranch-based application and want one consistent acceptor/pool story.
- You want ALPN-driven multiplexing of `h1` and `h2` (Cowboy + this library) on a single TLS port.
- You need Ranch's built-in draining, `ranch:procs/2`, or the `suspend_listener`/`resume_listener` controls.
- You want per-connection metrics hooked into Ranch's `ranch_proxy_header`, transport filters, etc.

For everything else, the built-in `h1:start_server/2,3` is simpler and has the same TLS hardening built in.

## Dependencies

```erlang
%% rebar.config
{deps, [
    {h1, "0.1.0", {git, "https://github.com/benoitc/erlang_h1.git", {tag, "0.1.0"}}},
    {ranch, "2.1.0"}
]}.
```

Ranch 2.x is assumed. The API shape hasn't changed for years, so 2.0+ all work.

## The minimal protocol

A Ranch protocol module is a callback module exporting `start_link/3`. It gets called for each accepted connection, receives the Ranch `Ref`, the Ranch transport module (`ranch_tcp` / `ranch_ssl`), and the protocol-specific options map.

```erlang
-module(h1_ranch_protocol).
-behaviour(ranch_protocol).

-export([start_link/3]).
-export([init/3]).

start_link(Ref, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Transport, Opts]),
    {ok, Pid}.

init(Ref, Transport, #{handler := Handler} = Opts) ->
    process_flag(trap_exit, true),
    {ok, Socket} = ranch:handshake(Ref),
    TransportMod = case Transport of
        ranch_ssl -> ssl;
        ranch_tcp -> gen_tcp
    end,
    ConnOpts = maps:without([handler], Opts),
    {ok, Conn} = h1_connection:start_link(server, Socket, self(), ConnOpts),
    ok = TransportMod:controlling_process(Socket, Conn),
    _ = h1_connection:activate(Conn),
    loop(Conn, Handler).

loop(Conn, Handler) ->
    receive
        {h1, Conn, {request, Id, M, P, Hs}} ->
            invoke(Handler, Conn, Id, M, P, Hs),
            loop(Conn, Handler);
        {h1, Conn, {upgrade, Id, _Proto, M, P, Hs}} ->
            %% Same callback; the handler looks at the Upgrade header
            %% and calls h1:accept_upgrade/3 if it wants to switch.
            invoke(Handler, Conn, Id, M, P, Hs),
            loop(Conn, Handler);
        {h1, Conn, {closed, _}} -> ok;
        {'EXIT', Conn, _}       -> ok;
        _Other                  -> loop(Conn, Handler)
    end.

invoke(Fun, Conn, Id, M, P, Hs) when is_function(Fun, 5) ->
    spawn(fun() -> Fun(Conn, Id, M, P, Hs) end);
invoke(Mod, Conn, Id, M, P, Hs) when is_atom(Mod) ->
    spawn(fun() -> Mod:handle_request(Conn, Id, M, P, Hs) end).
```

That's enough to serve traffic. Note the two things `h1_connection` requires and nothing else:

1. **Socket ownership**: call `controlling_process/2` on the appropriate transport module *after* `h1_connection:start_link` returns. The connection process must own the socket before it starts reading.
2. **Activation**: call `h1_connection:activate/1` to flip the socket to `{active, once}` mode and start the parser.

Everything else (parse, drive the state machine, emit events) is handled for you.

## How the socket handoff works

```
┌────────┐ 1. transport_accept  ┌──────────────┐
│ Ranch  │─────────────────────►│ protocol pid │
│        │                      │ (your init)  │
└────────┘                      └──────┬───────┘
                                       │ 2. h1_connection:start_link/4
                                       ▼
                                ┌──────────────┐
                                │ h1_connection│
                                │ (gen_statem) │
                                └──────┬───────┘
                                       │ 3. Transport:controlling_process(Sock, Conn)
                                       ▼
                                ┌──────────────┐
                                │ owns socket  │
                                └──────┬───────┘
                                       │ 4. h1_connection:activate(Conn)
                                       ▼
                                    parser starts
```

The protocol process (your `init/3` + `loop/2`) remains the **owner** of the connection. Protocol events (`{h1, Conn, …}`) are delivered to it — that's the `self()` passed as the Owner argument to `start_link/4`. If you want a different pid to receive events (e.g. a dedicated router), pass it explicitly:

```erlang
{ok, Conn} = h1_connection:start_link(server, Socket, RouterPid, #{}).
```

## A production-shaped protocol

Real deployments want configurable handlers, per-connection limits, correct handler supervision, and clean teardown on both Ranch- and h1-initiated shutdowns.

```erlang
-module(my_app_h1_protocol).
-behaviour(ranch_protocol).

-export([start_link/3]).
-export([init/3]).

-record(state, {
    conn    :: pid(),
    handler :: fun() | module(),
    pending = #{} :: #{h1:stream_id() => pid()}
}).

start_link(Ref, Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref, Transport, Opts]),
    {ok, Pid}.

init(Ref, Transport, #{handler := Handler} = Opts) ->
    process_flag(trap_exit, true),
    {ok, Socket} = ranch:handshake(Ref),
    TransportMod = case Transport of
        ranch_ssl -> ssl;
        ranch_tcp -> gen_tcp
    end,
    ConnOpts = maps:with(
        [idle_timeout, request_timeout, max_keepalive_requests,
         max_body_size, max_line_length, max_header_name_size,
         max_header_value_size, max_headers, pipeline],
        Opts),
    {ok, Conn} = h1_connection:start_link(server, Socket, self(), ConnOpts),
    case TransportMod:controlling_process(Socket, Conn) of
        ok ->
            ok = h1_connection:activate(Conn),
            loop(#state{conn = Conn, handler = Handler});
        {error, Reason} ->
            catch h1_connection:close(Conn),
            exit({controlling_process, Reason})
    end.

loop(#state{conn = Conn, handler = Handler, pending = Pending} = S) ->
    receive
        {h1, Conn, {request, Id, Method, Path, Headers}} ->
            Pid = spawn_handler(Handler, Conn, Id, Method, Path, Headers),
            loop(S#state{pending = Pending#{Id => Pid}});
        {h1, Conn, {upgrade, Id, _Proto, Method, Path, Headers}} ->
            Pid = spawn_handler(Handler, Conn, Id, Method, Path, Headers),
            loop(S#state{pending = Pending#{Id => Pid}});
        {h1, Conn, {data, Id, Data, End}} ->
            forward(Pending, Id, {data, Data, End}),
            loop(S);
        {h1, Conn, {trailers, Id, Tr}} ->
            forward(Pending, Id, {trailers, Tr}),
            loop(S);
        {h1, Conn, {stream_reset, Id, Reason}} ->
            forward(Pending, Id, {stream_reset, Reason}),
            loop(S#state{pending = maps:remove(Id, Pending)});
        {h1, Conn, {closed, _}} -> terminate(S);
        {'EXIT', Conn, _}       -> terminate(S);
        {'DOWN', _, process, Pid, _} ->
            %% Handler exited; drop it from Pending.
            P2 = maps:filter(fun(_, V) -> V =/= Pid end, Pending),
            loop(S#state{pending = P2});
        _ ->
            loop(S)
    end.

spawn_handler(Handler, Conn, Id, Method, Path, Headers) ->
    Parent = self(),
    {Pid, _} = spawn_monitor(fun() ->
        register_stream(Parent, Id, self()),
        try invoke(Handler, Conn, Id, Method, Path, Headers)
        catch Class:Reason:Stack ->
            error_logger:error_msg("h1 handler crash ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            catch h1:send_response(Conn, Id, 500,
                [{<<"content-length">>, <<"21">>},
                 {<<"content-type">>, <<"text/plain">>}]),
            catch h1:send_data(Conn, Id, <<"Internal Server Error">>, true)
        end
    end),
    Pid.

invoke(Fun, Conn, Id, M, P, Hs) when is_function(Fun, 5) ->
    Fun(Conn, Id, M, P, Hs);
invoke(Mod, Conn, Id, M, P, Hs) when is_atom(Mod) ->
    Mod:handle_request(Conn, Id, M, P, Hs).

register_stream(_Parent, _Id, _Pid) -> ok.  %% no-op; pending map is our own.

forward(Pending, Id, Msg) ->
    case maps:find(Id, Pending) of
        {ok, Pid} -> Pid ! {h1_stream, Id, Msg};
        error     -> ok
    end.

terminate(#state{conn = Conn, pending = Pending}) ->
    _ = [exit(P, shutdown) || P <- maps:values(Pending)],
    catch h1_connection:close(Conn),
    ok.
```

Key differences from the minimal version:

- **Per-request handler process** via `spawn_monitor`, so one slow or crashing handler doesn't block the connection loop. The stream events (`data`, `trailers`, `stream_reset`) arrive at the protocol process and are forwarded to the handler as `{h1_stream, Id, _}` messages — the same shape `h1_server` uses, so handler code is portable between `h1:start_server` and the Ranch wrapper.
- **Forwarded body events**: the handler collects `{h1_stream, Id, {data, _, _}}` / `{trailers, _}` to consume POST / chunked uploads.
- **Crash-safety**: if the user handler blows up, we still emit a 500 response and log the crash instead of letting the protocol process die silently.
- **Clean teardown** via `terminate/1`: on either socket close or h1_connection exit we kill pending handler processes and close the connection.

### Pipelining note

The minimal version above forwards `{request, …}` events as soon as they arrive, so multiple in-flight handlers could race on the socket. That breaks RFC 9112 §9.3 ordering. If you want pipelined requests handled correctly, block the loop on the current handler exiting before accepting the next request — that's exactly what the in-tree `h1_server` does. Copy its `pump/5` pattern:

```erlang
loop(#state{conn = Conn, handler = Handler}) ->
    receive
        {h1, Conn, {request, Id, M, P, Hs}} ->
            {Pid, MRef} = start_handler(Handler, Conn, Id, M, P, Hs),
            pump(Conn, Handler, Pid, MRef, Id);
        {h1, Conn, {closed, _}} -> ok
    end.

pump(Conn, Handler, Pid, MRef, Id) ->
    receive
        {h1, Conn, {data, Id, D, E}}    -> Pid ! {h1_stream, Id, {data, D, E}}, pump(Conn, Handler, Pid, MRef, Id);
        {h1, Conn, {trailers, Id, Tr}}  -> Pid ! {h1_stream, Id, {trailers, Tr}}, pump(Conn, Handler, Pid, MRef, Id);
        {'DOWN', MRef, process, Pid, _} -> loop(#state{conn = Conn, handler = Handler});
        {h1, Conn, {closed, _}}         -> ok
    end.
```

Handlers still run concurrently across connections; what's serialised is "next request on *this* connection waits until the prior handler exits."

## Starting the listener

Bind your protocol module to a Ranch listener:

```erlang
%% Plain TCP
{ok, _} = ranch:start_listener(my_h1,
    ranch_tcp,
    #{socket_opts => [{port, 8080}]},
    my_app_h1_protocol,
    #{handler => fun my_app:handle/5,
      idle_timeout => 60_000,
      request_timeout => 30_000,
      max_body_size => 16#400000}).  %% 4 MB

%% TLS
{ok, _} = ranch:start_listener(my_h1_tls,
    ranch_ssl,
    #{socket_opts => [
        {port, 8443},
        {certfile, "priv/cert.pem"},
        {keyfile, "priv/key.pem"},
        {alpn_preferred_protocols, [<<"http/1.1">>]}
    ]},
    my_app_h1_protocol,
    #{handler => my_app_handler}).
```

Stop it:

```erlang
ok = ranch:stop_listener(my_h1).
```

Bound port:

```erlang
Port = ranch:get_port(my_h1).
```

## Handling request bodies concurrently

The production-shaped protocol forwards `{data, _, _}` / `{trailers, _}` to the handler pid, so request bodies can be drained with `receive` in the handler:

```erlang
handle(Conn, Id, <<"POST">>, <<"/upload">>, Headers) ->
    Limit = case proplists:get_value(<<"content-length">>, Headers) of
        undefined -> 0;
        V -> binary_to_integer(V)
    end,
    Body = collect_body(Id, 0, Limit, <<>>),
    h1:send_response(Conn, Id, 201,
        [{<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    h1:send_data(Conn, Id, Body, true).

collect_body(_Id, N, Limit, Acc) when N >= Limit -> Acc;
collect_body(Id, N, Limit, Acc) ->
    receive
        {h1_stream, Id, {data, D, true}}  -> <<Acc/binary, D/binary>>;
        {h1_stream, Id, {data, D, false}} -> collect_body(Id, N + byte_size(D), Limit, <<Acc/binary, D/binary>>);
        {h1_stream, Id, {trailers, _}}    -> Acc
    after 30_000 ->
        %% handler timeout; connection timers will also catch this
        Acc
    end.
```

If you prefer a fully async, callback-per-chunk model, register a different process as the stream handler with `h1_connection:set_stream_handler/3` from inside the request handler:

```erlang
handle(Conn, Id, <<"POST">>, _, _) ->
    Worker = spawn_link(fun() -> body_worker(Conn, Id) end),
    _ = h1_connection:set_stream_handler(Conn, Id, Worker),
    ok.

body_worker(Conn, Id) ->
    receive
        {h1, Conn, {data, Id, D, true}} ->
            Hash = crypto:hash(sha256, D),
            h1:send_response(Conn, Id, 200,
                [{<<"content-length">>, <<"32">>}]),
            h1:send_data(Conn, Id, Hash, true);
        {h1, Conn, {data, Id, _, false}} ->
            body_worker(Conn, Id)
    end.
```

`set_stream_handler` takes the per-stream events off the connection owner's mailbox and delivers them to the given pid directly, without the protocol loop's forwarder in the path.

## Handling Upgrade through Ranch

The `{upgrade, …}` event is surfaced the same way `{request, …}` is, and the handler can call `h1:accept_upgrade/3` to switch protocols. After a successful upgrade, `h1_connection` stops with `{shutdown, upgraded}`, transfers the socket to the caller of `accept_upgrade`, and emits `{upgraded, …}` to the protocol owner. The protocol process should simply exit when it sees that event:

```erlang
{h1, Conn, {upgraded, _Id, _Proto, _Sock, _Buf, _Hdrs}} ->
    ok;  %% the handler owns the socket now; our loop is done.
```

## ALPN: h1 and h2 on the same port

To serve both HTTP/1.1 and HTTP/2 from one TLS listener, advertise both protocols and dispatch by negotiated ALPN:

```erlang
-module(multiplex_protocol).
-behaviour(ranch_protocol).
-export([start_link/3]).

start_link(Ref, ranch_ssl, Opts) ->
    {ok, spawn_link(fun() -> init(Ref, Opts) end)}.

init(Ref, Opts) ->
    {ok, Socket} = ranch:handshake(Ref),
    case ssl:negotiated_protocol(Socket) of
        {ok, <<"h2">>} ->
            ok = ssl:controlling_process(Socket, self()),
            cowboy_http2_protocol:init(Ref, ranch_ssl, Opts);
        {ok, <<"http/1.1">>} ->
            my_app_h1_protocol:init(Ref, ranch_ssl, Opts);
        {error, protocol_not_negotiated} ->
            my_app_h1_protocol:init(Ref, ranch_ssl, Opts);
        _ ->
            ssl:close(Socket)
    end.
```

Ranch listener opts:

```erlang
{ok, _} = ranch:start_listener(multiplex, ranch_ssl,
    #{socket_opts => [
        {port, 8443},
        {certfile, "cert.pem"},
        {keyfile, "key.pem"},
        {alpn_preferred_protocols, [<<"h2">>, <<"http/1.1">>]}
    ]},
    multiplex_protocol,
    HandlerOpts).
```

TLS picks one protocol per connection; the protocol module routes to the right library.

## Graceful shutdown

Ranch already supports drain-on-stop: `ranch:stop_listener/1` stops accepting new connections and can wait for the existing ones to finish. Because each accepted connection is a child of Ranch's connection supervisor, and your protocol process exits normally when `h1_connection` closes, no extra wiring is needed. If you want to hurry existing connections along, you can send each of them a signal:

```erlang
Conns = ranch:procs(my_h1, connections),
[begin
    Conn = find_h1_conn(ProtoPid),
    h1:goaway(Conn)  %% marks Connection: close on next response and shuts after drain
 end || ProtoPid <- Conns].
```

The `h1:goaway/1,2` call sets the `Connection: close` advertisement on the next response block, causing the state machine to shut once the current exchange finishes.

## Gotchas

- **Socket ownership timing.** `controlling_process/2` must be called on the right transport module (`gen_tcp` for TCP, `ssl` for TLS). Mis-match and the transfer silently fails. Using `Transport:controlling_process(Socket, Pid)` where `Transport` is the alias module (`ranch_tcp` / `ranch_ssl`) also works — the function is re-exported — but be consistent.
- **Activation before reading.** Don't skip `h1_connection:activate(Conn)`. The connection starts in passive mode; without the activate call it will never read from the socket and your clients will sit idle.
- **Process linking.** `h1_connection:start_link/4` links the connection to the calling process. If you don't trap exits, a connection error kills your protocol loop — usually what you want. If you do trap, handle `{'EXIT', Conn, Reason}` explicitly.
- **TLS handshake cost.** `ranch:handshake/1` completes the TLS handshake before your `init/3` sees the socket. If you care about per-connection cost at scale, raise Ranch's acceptor pool (`num_acceptors`) rather than hoping the handshake is cheap.
- **Max request sizes are per-connection options.** `max_body_size`, `max_line_length`, `max_header_*` are set at connection-start time via the `conn_opts` map. Changing them at runtime requires a new connection.
- **Ranch transport option shape.** In Ranch 2.x the socket options live under `socket_opts`, not at the top of the listener opts. Putting `certfile` at the top level produces `{error, bad_socket}` at listen time.

## See also

- [`h1:start_server/2,3`](../README.md#server) for the in-tree listener with the same acceptor pattern.
- [Upgrade + capsules](../README.md#upgrade--capsules) for the 101 handshake API.
- [Events reference](../README.md#events-reference) for the full list of `{h1, Conn, _}` messages.
