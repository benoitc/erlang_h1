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
-export([start_server/2, start_server/3, stop_server/1, server_port/1]).
-export([send_response/4]).

%% Common API
-export([send_data/3, send_data/4]).
-export([send_trailers/3]).
-export([cancel/2, cancel/3]).
-export([cancel_stream/2, cancel_stream/3]).
-export([set_stream_handler/3, set_stream_handler/4, unset_stream_handler/2]).
-export([goaway/1, goaway/2]).
-export([close/1]).
-export([get_settings/1, get_peer_settings/1]).
-export([controlling_process/2]).

%% HTTP/1.1-specific
-export([upgrade/3, upgrade/4]).
-export([accept_upgrade/3]).
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
    idle_timeout => timeout(),
    request_timeout => timeout()
}.

-type server_opts() :: #{
    transport => tcp | ssl,
    cert => binary() | string(),
    key => binary() | string(),
    cacerts => [binary()],
    handler := fun((connection(), stream_id(), binary(), binary(), headers()) -> any())
              | module(),
    acceptors => pos_integer(),
    handshake_timeout => timeout(),
    idle_timeout => timeout(),
    request_timeout => timeout(),
    max_keepalive_requests => pos_integer()
}.

-export_type([connection/0, stream_id/0, headers/0, status/0, server_ref/0,
              connect_opts/0, server_opts/0]).

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
               {reuseaddr, true}, {backlog, 1024}, {nodelay, true}],
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
            Defaults = [binary, {active, false}, {packet, raw},
                        {reuseaddr, true}, {backlog, 1024}, {nodelay, true},
                        {certfile, to_list(Cert)}, {keyfile, to_list(Key)},
                        {alpn_preferred_protocols, [<<"http/1.1">>]}],
            SslOpts = maps:get(ssl_opts, Opts, []),
            Listen = merge(Defaults, SslOpts),
            case ssl:listen(Port, Listen) of
                {ok, ListenSocket} ->
                    {ok, {_, Bound}} = ssl:sockname(ListenSocket),
                    spawn_listener(ssl, ListenSocket, Bound, Opts);
                {error, Reason} ->
                    {error, {listen_failed, Reason}}
            end;
        _ ->
            {error, {missing_required_option, [cert, key]}}
    end.

spawn_listener(Transport, ListenSocket, Bound, Opts) ->
    Handler = maps:get(handler, Opts),
    Acceptors = maps:get(acceptors, Opts, erlang:system_info(schedulers)),
    ConnOpts = maps:with([idle_timeout, request_timeout,
                          max_keepalive_requests, pipeline,
                          max_line_length, max_empty_lines,
                          max_header_name_size, max_header_value_size,
                          max_headers], Opts),
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
            {ok, {Pid, Ref, Bound}};
        {error, Reason} ->
            close_listen(Transport, ListenSocket),
            {error, Reason}
    end.

close_listen(gen_tcp, S) -> _ = gen_tcp:close(S), ok;
close_listen(ssl, S) -> _ = ssl:close(S), ok.

-spec stop_server(server_ref()) -> ok.
stop_server({Pid, Ref, _Port}) ->
    h1_listener:stop(Pid, Ref).

-spec server_port(server_ref()) -> inet:port_number().
server_port({_, _, Port}) -> Port.

-spec send_response(connection(), stream_id(), status(), headers()) ->
    ok | {error, term()}.
send_response(Conn, StreamId, Status, Headers) ->
    h1_connection:send_response(Conn, StreamId, Status, Headers).

%% ============================================================================
%% Common
%% ============================================================================

-spec send_data(connection(), stream_id(), binary()) -> ok | {error, term()}.
send_data(Conn, StreamId, Data) ->
    h1_connection:send_data(Conn, StreamId, Data).

-spec send_data(connection(), stream_id(), binary(), boolean()) ->
    ok | {error, term()}.
send_data(Conn, StreamId, Data, EndStream) ->
    h1_connection:send_data(Conn, StreamId, Data, EndStream).

-spec send_trailers(connection(), stream_id(), headers()) ->
    ok | {error, term()}.
send_trailers(Conn, StreamId, Trailers) ->
    h1_connection:send_trailers(Conn, StreamId, Trailers).

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

%% @doc Server: reply 101 Switching Protocols to an upgrade request.
-spec accept_upgrade(connection(), stream_id(), headers()) ->
    {ok, term(), binary()} | {error, term()}.
accept_upgrade(Conn, StreamId, ExtraHeaders) ->
    h1_connection:accept_upgrade(Conn, StreamId, ExtraHeaders).

%% @doc Server: send 100 Continue to a client waiting on Expect.
-spec continue(connection(), stream_id()) -> ok | {error, term()}.
continue(Conn, StreamId) ->
    h1_connection:continue(Conn, StreamId).

%% @doc Toggle request pipelining on a client connection.
-spec pipeline(connection(), boolean()) -> ok | {error, term()}.
pipeline(Conn, Enabled) when is_boolean(Enabled) ->
    h1_connection:set_pipeline(Conn, Enabled).

%% ============================================================================
%% Internal
%% ============================================================================

merge(Default, Override) ->
    Key = fun({K, _}) -> K; (K) -> K end,
    Kept = [D || D <- Default,
                 not lists:any(fun(O) -> Key(O) =:= Key(D) end, Override)],
    Kept ++ Override.

to_list(P) when is_list(P) -> P;
to_list(P) when is_binary(P) -> binary_to_list(P).
