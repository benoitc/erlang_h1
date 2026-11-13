%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc HTTP/1.1 public API.
%%
%% Mirrors the surface of `h2' (HTTP/2) and `quic_h3' (HTTP/3) so
%% applications can swap protocols without rewriting call sites.
%%
%% == Client ==
%% ```
%% {ok, Conn} = h1:connect("example.com", 80, #{}).
%% {ok, StreamId} = h1:request(Conn, <<"GET">>, <<"/">>,
%%                             [{<<"host">>, <<"example.com">>}]).
%% receive
%%     {h1, Conn, {response, StreamId, Status, _Headers}} -> ok
%% end.
%% ok = h1:close(Conn).
%% '''
%%
%% == Server ==
%% ```
%% {ok, S} = h1:start_server(8080, #{
%%     transport => tcp,
%%     handler => fun(Conn, Id, _Method, _Path, _Hs) ->
%%         h1:send_response(Conn, Id, 200, [{<<"content-length">>, <<"2">>}]),
%%         h1:send_data(Conn, Id, <<"ok">>, true)
%%     end}).
%% '''
-module(h1).

%% Client API
-export([connect/2, connect/3]).
-export([wait_connected/1, wait_connected/2]).
-export([request/2, request/3, request/4, request/5]).

%% Server API
-export([start_server/2, start_server/3, stop_server/1, stop_accepting/1,
         server_port/1]).
-export([serve_socket/2]).

-ifdef(TEST).
%% Lets the test suite drive a failed listen socket transfer.
-export([spawn_listener/4]).
-endif.
-export([send_response/4, respond/5, respond/6]).
-export([send_informational/4]).

%% Common API
-export([send_data/3, send_data/4]).
-export([consume/3]).
-export([send_trailers/3]).
-export([cancel/2, cancel/3]).
-export([cancel_stream/2, cancel_stream/3]).
-export([set_stream_handler/3, set_stream_handler/4, unset_stream_handler/2]).
-export([goaway/1, goaway/2]).
-export([close/1]).
-export([get_settings/1, get_peer_settings/1]).
-export([peername/1, peercert/1]).
-export([controlling_process/2]).

%% HTTP/1.1-specific
-export([upgrade/3, upgrade/4]).
-export([accept_upgrade/3]).
-export([accept_connect/3, accept_connect/4]).
-export([continue/2]).
-export([pipeline/2]).

-type connection() :: pid().
-type stream_id() :: non_neg_integer().
-type headers() :: [{binary(), binary()}].
-type status() :: 100..599.
-type server_ref() :: {pid(), reference(), inet:port_number()}.

-type connect_opts() :: #{
    transport => tcp | ssl,
    ssl_opts => [ssl:tls_client_option()],
    connect_timeout => timeout(),
    timeout => timeout(),
    pipeline => boolean(),
    max_keepalive_requests => pos_integer(),
    max_header_block_size => pos_integer(),
    idle_timeout => timeout(),
    request_timeout => timeout(),
    max_body_size => pos_integer() | infinity,
    flow_control => auto | manual,
    recv_window => pos_integer()
}.

-type server_opts() :: #{
    transport => tcp | ssl,
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    verify => verify_none | verify_peer,
    ssl_opts => [ssl:tls_option()],
    ip => inet:ip_address(),
    inet6 => boolean(),
    handler := fun((connection(), stream_id(), binary(), binary(), headers()) -> any())
              | module(),
    acceptors => pos_integer(),
    handshake_timeout => timeout(),
    idle_timeout => timeout(),
    request_timeout => timeout(),
    early_response_drain => early_response_drain(),
    lingering_timeout => timeout(),
    pipeline => boolean(),
    max_keepalive_requests => pos_integer(),
    max_line_length => pos_integer(),
    max_request_line_size => pos_integer() | infinity,
    max_empty_lines => non_neg_integer(),
    max_header_name_size => pos_integer(),
    max_header_value_size => pos_integer(),
    max_headers => pos_integer(),
    max_header_block_size => pos_integer(),
    max_body_size => pos_integer() | infinity,
    flow_control => auto | manual,
    recv_window => pos_integer()
}.

%% Early-response inbound drain budget (lingering close). `{MaxBytes, MaxMs}'
%% reads and discards an unfinished request body after an early response, up
%% to MaxBytes / MaxMs (either component `infinity'), before closing. `0'
%% disables the drain and closes immediately. Default `{infinity, 30000}'.
-type early_response_drain() ::
    0 | {non_neg_integer() | infinity, non_neg_integer() | infinity}.

-type respond_opts() :: #{early_response_drain => early_response_drain()}.

-export_type([connection/0, stream_id/0, headers/0, status/0, server_ref/0,
              connect_opts/0, server_opts/0, early_response_drain/0,
              respond_opts/0]).

%% ============================================================================
%% Client
%% ============================================================================

-spec connect(string() | binary(), inet:port_number()) ->
    {ok, connection()} | {error, term()}.
connect(Host, Port) ->
    connect(Host, Port, #{}).

-spec connect(string() | binary(), inet:port_number(), connect_opts()) ->
    {ok, connection()} | {error, term()}.
connect(Host, Port, Opts) ->
    h1_client:connect(Host, Port, Opts).

-spec wait_connected(connection()) -> ok | {error, term()}.
wait_connected(Conn) -> h1_connection:wait_connected(Conn).

-spec wait_connected(connection(), timeout()) -> ok | {error, term()}.
wait_connected(Conn, Timeout) -> h1_connection:wait_connected(Conn, Timeout).

%% @doc Send a request using h2-compatible pseudo-headers. The list
%% may contain `:method', `:path', `:authority'; they're translated
%% into the HTTP/1.1 request line + `Host' header.
-spec request(connection(), headers()) ->
    {ok, stream_id()} | {error, term()}.
request(Conn, Headers) ->
    request(Conn, Headers, #{}).

%% `Opts' may carry `body' and `flow_control => auto | manual'. With
%% `manual' the client stops reading the socket once `recv_window' bytes of
%% this response's body were delivered and not given back with consume/3, as
%% with `h2:request/3' and `quic_h3:request/3'. The default is the
%% connection's `flow_control' (`auto' unless set in connect/3).
-spec request(connection(), headers(), map()) ->
    {ok, stream_id()} | {error, term()}.
request(Conn, Headers, Opts) ->
    {Method, Path, Rest0} = extract_pseudo(Headers),
    Rest1 = case proplists:is_defined(<<"host">>, Rest0) of
        true -> Rest0;
        false ->
            case proplists:get_value(<<":authority">>, Headers) of
                undefined -> Rest0;
                Authority -> [{<<"host">>, Authority} | Rest0]
            end
    end,
    SendOpts = maps:without([protocol, end_stream], Opts),
    case maps:get(body, Opts, undefined) of
        undefined ->
            h1_connection:send_request(Conn, Method, Path, Rest1, SendOpts);
        Body ->
            h1_connection:send_request(Conn, Method, Path, Rest1,
                                       SendOpts#{body => Body,
                                                 end_stream => true})
    end.

-spec request(connection(), binary(), binary(), headers()) ->
    {ok, stream_id()} | {error, term()}.
request(Conn, Method, Path, Headers) ->
    h1_connection:send_request(Conn, Method, Path, Headers, #{}).

-spec request(connection(), binary(), binary(), headers(), binary()) ->
    {ok, stream_id()} | {error, term()}.
request(Conn, Method, Path, Headers, Body) ->
    h1_connection:send_request(Conn, Method, Path, Headers,
                               #{body => Body, end_stream => true}).

extract_pseudo(Headers) ->
    Method = proplists:get_value(<<":method">>, Headers, <<"GET">>),
    Path = proplists:get_value(<<":path">>, Headers, <<"/">>),
    Rest = [{N, V} || {N, V} <- Headers,
                      N =/= <<":method">>,
                      N =/= <<":path">>,
                      N =/= <<":scheme">>,
                      N =/= <<":authority">>,
                      N =/= <<":protocol">>],
    {Method, Path, Rest}.

%% ============================================================================
%% Server
%% ============================================================================

-spec start_server(atom(), inet:port_number(), server_opts()) ->
    {ok, server_ref()} | {error, term()}.
start_server(Name, Port, Opts) when is_atom(Name) ->
    case start_server(Port, Opts) of
        {ok, Ref} ->
            persistent_term:put({?MODULE, server, Name}, Ref),
            {ok, Ref};
        Other ->
            Other
    end.

-spec start_server(inet:port_number(), server_opts()) ->
    {ok, server_ref()} | {error, term()}.
start_server(Port, Opts) ->
    Transport = maps:get(transport, Opts, tcp),
    case maps:find(handler, Opts) of
        {ok, _} ->
            case Transport of
                tcp -> start_tcp(Port, Opts);
                ssl -> start_ssl(Port, Opts)
            end;
        error ->
            {error, {missing_required_option, [handler]}}
    end.

start_tcp(Port, Opts) ->
    TcpOpts = [binary, {active, false}, {packet, raw},
               {reuseaddr, true}, {backlog, 1024}, {nodelay, true}]
              ++ socket_addr_opts(Opts),
    case gen_tcp:listen(Port, TcpOpts) of
        {ok, ListenSocket} ->
            {ok, {_, Bound}} = inet:sockname(ListenSocket),
            spawn_listener(gen_tcp, ListenSocket, Bound, Opts);
        {error, Reason} ->
            {error, {listen_failed, Reason}}
    end.

start_ssl(Port, Opts) ->
    case {maps:find(cert, Opts), maps:find(key, Opts)} of
        {{ok, Cert}, {ok, Key}} ->
            case server_ssl_opts(Cert, Key, Opts) of
                {ok, Listen} ->
                    case ssl:listen(Port, Listen) of
                        {ok, ListenSocket} ->
                            {ok, {_, Bound}} = ssl:sockname(ListenSocket),
                            spawn_listener(ssl, ListenSocket, Bound, Opts);
                        {error, Reason} ->
                            {error, {listen_failed, Reason}}
                    end;
                {error, _} = Error ->
                    Error
            end;
        _ ->
            {error, {missing_required_option, [cert, key]}}
    end.

%% Build the ssl:listen/2 option list. Honours `verify' (default
%% `verify_none'), `cacerts' (needed for mutual TLS), and `ssl_opts' as a raw
%% override. `verify_peer' without CA certificates is rejected so a
%% misconfigured server fails closed instead of accepting unauthenticated
%% peers — same contract as h2.
server_ssl_opts(Cert, Key, Opts) ->
    Verify = maps:get(verify, Opts, verify_none),
    CACerts = maps:get(cacerts, Opts, []),
    case Verify of
        verify_peer when CACerts =:= [] ->
            {error, verify_peer_requires_cacerts};
        _ ->
            Defaults = [binary, {active, false}, {packet, raw},
                        {reuseaddr, true}, {backlog, 1024}, {nodelay, true},
                        {certfile, to_list(Cert)}, {keyfile, to_list(Key)},
                        {alpn_preferred_protocols, [<<"http/1.1">>]},
                        {verify, Verify}],
            %% `verify_peer' alone lets a TLS 1.2 client skip its certificate
            %% (`fail_if_no_peer_cert' defaults to false), which is not what
            %% asking for client authentication means. Require the
            %% certificate; `ssl_opts' can still override.
            Auth = case {Verify, CACerts} of
                {_, []} -> [];
                {verify_peer, _} -> [{cacerts, CACerts},
                                     {fail_if_no_peer_cert, true}];
                {_, _} -> [{cacerts, CACerts}]
            end,
            SslOpts = maps:get(ssl_opts, Opts, []),
            Base = Defaults ++ Auth ++ socket_addr_opts(Opts),
            {ok, merge(Base, SslOpts)}
    end.

spawn_listener(Transport, ListenSocket, Bound, Opts) ->
    Handler = maps:get(handler, Opts),
    Acceptors = maps:get(acceptors, Opts, erlang:system_info(schedulers)),
    ConnOpts = conn_opts(Opts),
    ServerOpts = maps:with([handshake_timeout], Opts),
    Ref = make_ref(),
    Args = #{transport => Transport,
             listen_socket => ListenSocket,
             acceptor_count => Acceptors,
             ref => Ref,
             handler => Handler,
             conn_opts => ConnOpts,
             server_opts => ServerOpts},
    case h1_sup:start_listener(Args) of
        {ok, Pid} ->
            %% The listen socket closes when its controlling process exits.
            %% Hand it to the listener so the server does not depend on the
            %% caller staying alive.
            case transfer_socket(Transport, ListenSocket, Pid) of
                ok ->
                    {ok, {Pid, Ref, Bound}};
                {error, Reason} ->
                    ok = h1_listener:stop(Pid, Ref),
                    close_socket(Transport, ListenSocket),
                    {error, {controlling_process, Reason}}
            end;
        {error, Reason} ->
            close_socket(Transport, ListenSocket),
            {error, Reason}
    end.

close_socket(gen_tcp, S) -> _ = gen_tcp:close(S), ok;
close_socket(ssl, S) -> _ = ssl:close(S), ok.

%% The per-connection slice of the server options. Every path that starts a
%% server connection (`spawn_listener/4', `serve_socket/2') goes through
%% this one list, so an option cannot be wired into one path and forgotten
%% in the other.
conn_opts(Opts) ->
    maps:with([idle_timeout, request_timeout,
               early_response_drain, lingering_timeout,
               max_keepalive_requests, pipeline,
               max_line_length, max_request_line_size, max_empty_lines,
               max_header_name_size, max_header_value_size,
               max_headers, max_header_block_size,
               max_body_size, flow_control, recv_window], Opts).

%% @doc Serve an already-accepted connection: run the server loop on a
%% socket someone else accepted. The caller has completed the TCP accept
%% and, for TLS, the handshake and ALPN negotiation — h1 does not
%% handshake again, so `cert', `key', `verify' and `ssl_opts' are ignored
%% here. Use it to serve HTTP/1.1 and HTTP/2 on one TLS port: negotiate
%% ALPN yourself, then hand `http/1.1' sockets to this function.
%%
%% Requires `handler'; every other option is the per-connection subset
%% `start_server/2' accepts (timeouts, parser limits, drain budget).
%%
%% The socket must be passive (`{active, false}'): h1 arms it itself, and
%% bytes an active socket already delivered to the caller's mailbox cannot
%% be recovered.
%%
%% On `{ok, Pid}' the returned process is linked to the caller and owns
%% the socket: it is the socket's controlling process from that point on,
%% and closes it when it exits (unless the socket was handed off by
%% Upgrade or CONNECT). Killing the caller therefore closes the
%% connection. These connections belong to no listener, so
%% `stop_server/1' does not close them.
%%
%% ```
%% {ok, Sock} = ssl:handshake(Raw, 5000),
%% {ok, <<"http/1.1">>} = ssl:negotiated_protocol(Sock),
%% {ok, _Pid} = h1:serve_socket(Sock, #{handler => fun my_app:handle/5}).
%% '''
-spec serve_socket(ssl:sslsocket() | gen_tcp:socket(), server_opts()) ->
    {ok, pid()} | {error, term()}.
serve_socket(Socket, Opts) ->
    case maps:find(handler, Opts) of
        {ok, Handler} ->
            Transport = h1_connection:transport_of(Socket),
            Args = [Socket, Transport, Handler, conn_opts(Opts), #{}],
            Pid = proc_lib:spawn_link(h1_server, init_serve, Args),
            case transfer_socket(Transport, Socket, Pid) of
                ok ->
                    Pid ! {h1_server, socket_ready},
                    {ok, Pid};
                {error, Reason} ->
                    Pid ! {h1_server, transfer_failed},
                    _ = close_socket(Transport, Socket),
                    {error, {controlling_process, Reason}}
            end;
        error ->
            {error, {missing_required_option, [handler]}}
    end.

transfer_socket(gen_tcp, Socket, Pid) -> gen_tcp:controlling_process(Socket, Pid);
transfer_socket(ssl, Socket, Pid) -> ssl:controlling_process(Socket, Pid).

%% @doc Stop a server. Synchronous: closes the listen socket, the
%% acceptor pool, and every accepted connection (kept-alive and
%% in-flight included) before returning.
-spec stop_server(server_ref()) -> ok.
stop_server({Pid, Ref, _Port} = ServerRef) ->
    erase_server_term(ServerRef),
    h1_listener:stop(Pid, Ref).

%% @doc Stop accepting new connections while continuing to serve the
%% established ones (graceful drain). Synchronous. Call
%% `stop_server/1' afterwards to close the remaining connections.
-spec stop_accepting(server_ref()) -> ok.
stop_accepting({Pid, Ref, _Port}) ->
    h1_listener:stop_accepting(Pid, Ref).

%% Drop any name->ref registration made by start_server/3 so repeated
%% start/stop cycles don't leak persistent_term entries.
erase_server_term(ServerRef) ->
    _ = [persistent_term:erase(K)
         || {{?MODULE, server, _} = K, V} <- persistent_term:get(),
            V =:= ServerRef],
    ok.

-spec server_port(server_ref()) -> inet:port_number().
server_port({_, _, Port}) -> Port.

-spec send_response(connection(), stream_id(), status(), headers()) ->
    ok | {error, term()}.
%% @doc Server: send the response header block. When the headers carry
%% neither Content-Length nor Transfer-Encoding, the body is sent chunked.
%% Follow up with send_data/4 and end the stream with `EndStream = true' or
%% with send_trailers/3.
%%
%% A response to HEAD and any 204 or 304 has no body (RFC 9112 §6.3): h1
%% drops any Transfer-Encoding, drops Content-Length on a 204, keeps one you
%% set on a 304 or HEAD response, and writes nothing after the header block.
%% Body data and trailers you send afterwards are discarded and the calls
%% return `ok'; end the stream as usual. A 1xx status is sent as an interim
%% response, as with send_informational/4.
%%
%% A `Connection: close' you set makes this the last response: h1 closes the
%% connection once it ends and does not process later requests. The same
%% holds for respond/5,6.
send_response(Conn, StreamId, Status, Headers) ->
    h1_connection:send_response(Conn, StreamId, Status, Headers).

-spec respond(connection(), stream_id(), status(), headers(), iodata()) ->
    ok | {error, term()}.
%% @doc Server: send a complete response (status, headers, and body) in a
%% single socket write and end the stream. A Content-Length is added when
%% the headers carry neither Content-Length nor Transfer-Encoding, so the
%% body is sent fixed-length rather than chunked. Use this for fully-known
%% bodies; use send_response/4 + send_data/4 for streaming.
%%
%% For a response to HEAD, a 204 or a 304 the body is not sent, as for
%% send_response/4. On HEAD the Content-Length is that of `Body', so a GET
%% handler can answer HEAD unchanged; an empty `Body' adds none. A 1xx status
%% is sent as an interim response and the body is discarded.
%%
%% If the request body has not been fully received when this is called (an
%% early response, e.g. rejecting an oversized upload with 413), h1 adds
%% `Connection: close', sends the response, then drains and discards the rest
%% of the inbound body before closing the socket. The response is delivered
%% cleanly and the connection is not reused. The drain is bounded by the
%% listener's `early_response_drain' budget (default `{infinity, 30000}').
respond(Conn, StreamId, Status, Headers, Body) ->
    h1_connection:respond(Conn, StreamId, Status, Headers, Body).

-spec respond(connection(), stream_id(), status(), headers(), iodata(),
              respond_opts()) -> ok | {error, term()}.
%% @doc As respond/5, with per-response options. `early_response_drain'
%% overrides the listener's drain budget for this response only: pass a
%% larger `{MaxBytes, MaxMs}' to a known-large upload endpoint, or `0' to
%% close immediately without draining.
respond(Conn, StreamId, Status, Headers, Body, Opts) ->
    h1_connection:respond(Conn, StreamId, Status, Headers, Body, Opts).

%% ============================================================================
%% Common
%% ============================================================================

-spec send_data(connection(), stream_id(), binary()) -> ok | {error, term()}.
send_data(Conn, StreamId, Data) ->
    h1_connection:send_data(Conn, StreamId, Data).

-spec send_data(connection(), stream_id(), binary(), boolean()) ->
    ok | {error, term()}.
%% @doc Send a body chunk. With `EndStream = true' the stream is ended; if the
%% request body was not fully received first (server side), h1 advertises
%% `Connection: close' and drains the remaining inbound body before closing,
%% as for respond/5. On a response with no body (HEAD, 204, 304) `Data' is
%% discarded and nothing is written.
send_data(Conn, StreamId, Data, EndStream) ->
    h1_connection:send_data(Conn, StreamId, Data, EndStream).

-spec send_trailers(connection(), stream_id(), headers()) ->
    ok | {error, term()}.
%% @doc Send the trailer section and end the stream. The response must be
%% chunked, else `{error, trailers_require_chunked}'. On a response with no
%% body (HEAD, 204, 304) the trailers are discarded and the stream ends.
%% Ending the stream here works like send_data/4 with `EndStream = true': a
%% pending close or early-response drain runs after the trailers.
send_trailers(Conn, StreamId, Trailers) ->
    h1_connection:send_trailers(Conn, StreamId, Trailers).

-spec consume(connection(), stream_id(), non_neg_integer()) ->
    ok | {error, unknown_stream}.
%% @doc Give back `Bytes' of body credit, as with `h2:consume/3' and
%% `quic_h3:consume/3'. Only matters with `flow_control => manual': the
%% connection stops reading the socket once `recv_window' body bytes were
%% delivered and not consumed, and resumes when consume/3 brings the count
%% back under the window. Count the body bytes you received (the `Data' of
%% each data event), never framing or trailers.
%%
%% On a server, `manual' is a server option and covers request bodies; on a
%% client, it is set per request (request/3) or for the connection
%% (connect/3) and covers response bodies.
%%
%% Returns `ok' without doing anything on an `auto' server or an `auto'
%% client stream, and `{error, unknown_stream}' once the body of `StreamId'
%% has ended.
consume(Conn, StreamId, Bytes) ->
    h1_connection:consume(Conn, StreamId, Bytes).

-spec cancel(connection(), stream_id()) -> ok | {error, term()}.
cancel(Conn, StreamId) ->
    h1_connection:cancel_stream(Conn, StreamId).

-spec cancel(connection(), stream_id(), term()) -> ok | {error, term()}.
cancel(Conn, StreamId, Reason) ->
    h1_connection:cancel_stream(Conn, StreamId, Reason).

-spec cancel_stream(connection(), stream_id()) -> ok | {error, term()}.
cancel_stream(Conn, StreamId) -> cancel(Conn, StreamId).

-spec cancel_stream(connection(), stream_id(), term()) -> ok | {error, term()}.
cancel_stream(Conn, StreamId, Reason) -> cancel(Conn, StreamId, Reason).

-spec set_stream_handler(connection(), stream_id(), pid()) ->
    ok | {error, term()}.
set_stream_handler(Conn, StreamId, Pid) ->
    h1_connection:set_stream_handler(Conn, StreamId, Pid).

-spec set_stream_handler(connection(), stream_id(), pid(), map()) ->
    ok | {error, term()}.
%% @doc As set_stream_handler/3. On a client, `#{flow_control => manual}'
%% makes the handler consume the response body with consume/3; if the
%% handler exits first, the window is released and the rest of the body is
%% read and dropped.
set_stream_handler(Conn, StreamId, Pid, Opts) ->
    h1_connection:set_stream_handler(Conn, StreamId, Pid, Opts).

-spec unset_stream_handler(connection(), stream_id()) -> ok.
unset_stream_handler(Conn, StreamId) ->
    h1_connection:unset_stream_handler(Conn, StreamId).

-spec goaway(connection()) -> ok | {error, term()}.
goaway(Conn) -> h1_connection:send_goaway(Conn).

-spec goaway(connection(), term()) -> ok | {error, term()}.
goaway(Conn, Reason) -> h1_connection:send_goaway(Conn, Reason).

-spec close(connection()) -> ok.
close(Conn) -> h1_connection:close(Conn).

-spec get_settings(connection()) -> map().
get_settings(Conn) -> h1_connection:get_settings(Conn).

-spec get_peer_settings(connection()) -> map().
get_peer_settings(Conn) -> h1_connection:get_peer_settings(Conn).

%% @doc Address and port of the connected peer. Works in both modes:
%% the remote client on a server connection, the remote server on a
%% client connection.
-spec peername(connection()) ->
    {ok, {inet:ip_address(), inet:port_number()}} | {error, term()}.
peername(Conn) -> h1_connection:peername(Conn).

%% @doc DER-encoded certificate the peer presented in the TLS handshake:
%% the client's certificate on a server connection, the server's on a
%% client connection.
%%
%% Pass the connection, or the socket that `accept_upgrade/3' or
%% `accept_connect/3,4' returned once the socket was handed over (the
%% connection process is gone by then and answers `{error, closed}').
%%
%% A client only sends a certificate when the server asks for one: start
%% the server with `verify => verify_peer' and `cacerts'. Returns
%% `{error, no_peercert}' when the peer sent none or the connection is
%% plain TCP.
%%
%% ```
%% handle(Conn, StreamId, _Method, _Path, _Headers) ->
%%     case h1:peercert(Conn) of
%%         {ok, Der} -> authorize(public_key:pkix_decode_cert(Der, otp));
%%         {error, _} -> h1:respond(Conn, StreamId, 403, [], <<>>)
%%     end.
%% '''
-spec peercert(connection() | ssl:sslsocket() | gen_tcp:socket()) ->
    {ok, binary()} | {error, term()}.
peercert(Conn) when is_pid(Conn) ->
    h1_connection:peercert(Conn);
peercert(Socket) ->
    case h1_connection:transport_of(Socket) of
        ssl -> ssl:peercert(Socket);
        gen_tcp -> {error, no_peercert}
    end.

-spec controlling_process(connection(), pid()) -> ok | {error, term()}.
controlling_process(Conn, Pid) ->
    h1_connection:controlling_process(Conn, Pid).

%% ============================================================================
%% HTTP/1.1-specific
%% ============================================================================

%% @doc Client: send an Upgrade request and wait for 101 Switching Protocols.
-spec upgrade(connection(), binary(), headers()) ->
    {ok, stream_id(), term(), binary(), headers()} | {error, term()}.
upgrade(Conn, Protocol, Headers) ->
    h1_connection:upgrade(Conn, Protocol, Headers).

-spec upgrade(connection(), binary(), headers(), timeout()) ->
    {ok, stream_id(), term(), binary(), headers()} | {error, term()}.
upgrade(Conn, Protocol, Headers, Timeout) ->
    h1_connection:upgrade(Conn, Protocol, Headers, Timeout).

%% @doc Server: reply 101 Switching Protocols to an upgrade request
%% and take ownership of the raw socket. Injects the `Connection:
%% Upgrade' and `Upgrade: <proto>' framing headers itself and strips
%% any caller-supplied copies (case-insensitive), so the 101 carries
%% exactly one of each. Pass only protocol-specific extras in
%% ExtraHeaders (e.g. `sec-websocket-accept').
%%
%% The socket is passive when this returns. Bytes the client already sent are in
%% the returned buffer or still in the socket, in order. If the connection
%% already saw a close or error, the caller also gets that as a socket message,
%% such as `{tcp_closed, Socket}'.
-spec accept_upgrade(connection(), stream_id(), headers()) ->
    {ok, term(), binary()} | {error, term()}.
accept_upgrade(Conn, StreamId, ExtraHeaders) ->
    h1_connection:accept_upgrade(Conn, StreamId, ExtraHeaders).

%% @doc Server: reply 200 Connection Established to a classic HTTP/1.1
%% CONNECT (RFC 9110 §9.3.6, RFC 9112 §3.2.3 authority-form request-target)
%% and take ownership of the raw socket. Mirror of `accept_upgrade/3' for
%% the 101 Switching Protocols case, but writes status 200 and injects no
%% Connection/Upgrade headers so bytes after CRLF belong to the tunnel.
%% The handover guarantees are the same as for `accept_upgrade/3'.
-spec accept_connect(connection(), stream_id(), headers()) ->
    {ok, gen_tcp | ssl, term(), binary()} | {error, term()}.
accept_connect(Conn, StreamId, ExtraHeaders) ->
    h1_connection:accept_connect(Conn, StreamId, ExtraHeaders).

-spec accept_connect(connection(), stream_id(), headers(), timeout()) ->
    {ok, gen_tcp | ssl, term(), binary()} | {error, term()}.
accept_connect(Conn, StreamId, ExtraHeaders, Timeout) ->
    h1_connection:accept_connect(Conn, StreamId, ExtraHeaders, Timeout).

%% @doc Server: send 100 Continue to a client waiting on Expect.
-spec continue(connection(), stream_id()) -> ok | {error, term()}.
continue(Conn, StreamId) ->
    h1_connection:continue(Conn, StreamId).

%% @doc Server: send an interim (1xx) response, e.g. 103 Early Hints,
%% ahead of the final response. May be called several times per stream,
%% until the final response headers are sent. 101 is rejected (use the
%% Upgrade machinery), and so are HTTP/1.0 clients (RFC 9110 §15.2).
-spec send_informational(connection(), stream_id(), 100..199, headers()) ->
    ok | {error, term()}.
send_informational(Conn, StreamId, Status, Headers) ->
    h1_connection:send_informational(Conn, StreamId, Status, Headers).

%% @doc Toggle request pipelining on a client connection.
-spec pipeline(connection(), boolean()) -> ok | {error, term()}.
pipeline(Conn, Enabled) when is_boolean(Enabled) ->
    h1_connection:set_pipeline(Conn, Enabled).

%% ============================================================================
%% Internal
%% ============================================================================

%% Build inet listen options from the `ip'/`inet6' server opts. An IPv6
%% `ip' tuple (or `inet6 => true') selects the inet6 family; `ip' sets the
%% bind address. Returned as a list suitable for gen_tcp/ssl listen opts.
socket_addr_opts(Opts) ->
    IP = maps:get(ip, Opts, undefined),
    Family = case {IP, maps:get(inet6, Opts, false)} of
        {{_, _, _, _, _, _, _, _}, _} -> [inet6];
        {_, true} -> [inet6];
        _ -> []
    end,
    Addr = case IP of
        undefined -> [];
        _ -> [{ip, IP}]
    end,
    Family ++ Addr.

merge(Default, Override) ->
    Key = fun({K, _}) -> K; (K) -> K end,
    Kept = [D || D <- Default,
                 not lists:any(fun(O) -> Key(O) =:= Key(D) end, Override)],
    Kept ++ Override.

to_list(P) when is_list(P) -> P;
to_list(P) when is_binary(P) -> binary_to_list(P).
