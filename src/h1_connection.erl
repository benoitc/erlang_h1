%% @doc HTTP/1.1 connection gen_statem.
%%
%% Owns a single TCP or TLS socket and drives the h1_parse_erl parser in
%% both client and server modes. Emits protocol events to the owner pid
%% (or a per-stream handler if set) using a tuple shape identical to
%% erlang_h2 / erlang_quic_h3 so callers can swap protocols:
%%
%%   {h1, Conn, connected}
%%   {h1, Conn, {request,       StreamId, Method, Path, Headers}}   % server
%%   {h1, Conn, {response,      StreamId, Status, Headers}}         % client
%%   {h1, Conn, {informational, StreamId, Status, Headers}}         % 1xx
%%   {h1, Conn, {data,          StreamId, Data, EndStream}}
%%   {h1, Conn, {trailers,      StreamId, Trailers}}
%%   {h1, Conn, {upgrade,       StreamId, Protocol, Headers}}       % server
%%   {h1, Conn, {upgraded,      StreamId, Protocol, Sock, Buf, Hs}} % client
%%   {h1, Conn, {stream_reset,  StreamId, Reason}}
%%   {h1, Conn, {goaway,        LastStreamId, Reason}}
%%   {h1, Conn, {closed,        Reason}}
%%
%% Keep-alive, client-side pipelining, Expect: 100-continue, trailers
%% and Upgrade (101 Switching Protocols) are all handled here.
-module(h1_connection).
-behaviour(gen_statem).

%% Public API (mirrors h2_connection where possible)
-export([start_link/3, start_link/4]).
-export([activate/1]).
-export([wait_connected/1, wait_connected/2]).
-export([send_request/5, send_request_with_body/5]).
-export([send_response/4]).
-export([send_data/3, send_data/4]).
-export([send_trailers/3]).
-export([continue/2]).
-export([upgrade/3, upgrade/4]).
-export([accept_upgrade/3]).
-export([accept_connect/3, accept_connect/4]).
-export([cancel_stream/2, cancel_stream/3]).
-export([send_goaway/1, send_goaway/2]).
-export([set_stream_handler/3, set_stream_handler/4, unset_stream_handler/2]).
-export([controlling_process/2]).
-export([get_settings/1, get_peer_settings/1]).
-export([set_pipeline/2]).
-export([close/1]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3, code_change/4]).
-export([handle_event/4]).

-include("h1.hrl").

-type mode() :: client | server.
-type stream_id() :: non_neg_integer().
-type version() :: {non_neg_integer(), non_neg_integer()}.
-type headers() :: [{binary(), iodata()}].
-type reason() :: term().

-record(stream, {
    id                    :: stream_id(),
    state = idle          :: idle | open | half_closed_local | half_closed_remote | closed,
    method                :: undefined | binary(),
    path                  :: undefined | binary(),
    status                :: undefined | non_neg_integer(),
    version = ?HTTP_1_1   :: version(),
    req_headers = []      :: headers(),
    resp_headers = []     :: headers(),
    trailers = []         :: headers(),
    %% Per-stream event handler (if set via set_stream_handler/3).
    handler               :: undefined | pid(),
    handler_opts = #{}    :: map(),
    %% Queued body chunks received before handler was set.
    recv_buffer = []      :: [{binary() | {trailers, headers()}, boolean()}],
    %% Server: caller asked for Expect: 100-continue.
    expect_continue = false :: boolean(),
    continue_sent = false   :: boolean(),
    %% Client: bytes staged waiting for 100 Continue before being sent.
    pending_body            :: undefined | {iodata(), chunked | identity, boolean()},
    %% Response-side framing.
    resp_framing          :: undefined | {content_length, non_neg_integer()}
                                        | chunked | no_body,
    %% Did we already emit end_stream=true for incoming body data?
    recv_ended = false    :: boolean(),
    %% Client synchronous upgrade bookkeeping.
    upgrade_from          :: undefined | {pid(), reference()},
    upgrade_protocol      :: undefined | binary(),
    closed_reason         :: undefined | reason()
}).

-record(state, {
    mode                   :: mode(),
    socket,
    transport              :: gen_tcp | ssl,
    owner                  :: pid(),
    owner_ref              :: reference(),
    peer                   :: {inet:ip_address(), inet:port_number()} | undefined,
    %% Client-side: hostname (or IP literal) used to build the default
    %% `Host:' header when the caller omits it.
    peer_host              :: undefined | binary(),
    %% Parser.
    parser                 :: h1_parse_erl:parser(),
    %% Current in-flight stream on the wire.
    current_stream         :: undefined | stream_id(),
    %% All streams keyed by id.
    streams = #{}          :: #{stream_id() => #stream{}},
    %% Client: pipelined request order (FIFO of stream ids awaiting response).
    pending = queue:new()  :: queue:queue(stream_id()),
    %% ID generation (starts at 1, increments on each request/response pair).
    next_stream_id = 1     :: stream_id(),
    %% Connection policy.
    keepalive = true       :: boolean(),
    pipeline_enabled = true :: boolean(),
    max_keepalive_requests = 100 :: pos_integer(),
    requests_served = 0    :: non_neg_integer(),
    %% Timeouts.
    idle_timeout = 300000  :: timeout(),
    request_timeout = 60000 :: timeout(),
    %% Upgrade handoff (synchronous server-side accept).
    upgrade_accept         :: undefined | {pid(), reference(), stream_id()},
    %% Shutdown policy.
    close_after = false    :: boolean(),
    goaway_sent = false    :: boolean(),
    %% Connection lifecycle.
    connected_acked = false :: boolean(),
    wait_connected_waiters = [] :: [{pid(), reference()}],
    %% True once the socket has been controlling_process'd to someone else
    %% (after a successful Upgrade). terminate/3 must not close it then.
    socket_handed_off = false :: boolean(),
    %% Parser limits forwarded from opts.
    parser_opts = []       :: [h1_parse_erl:parser_option()]
}).

%% ----------------------------------------------------------------------------
%% Public API
%% ----------------------------------------------------------------------------

start_link(client, Socket, Opts) ->
    gen_statem:start_link(?MODULE, {client, Socket, self(), Opts}, []);
start_link(server, Socket, Opts) ->
    gen_statem:start_link(?MODULE, {server, Socket, self(), Opts}, []).

start_link(Mode, Socket, Owner, Opts) ->
    gen_statem:start_link(?MODULE, {Mode, Socket, Owner, Opts}, []).

activate(Pid) ->
    gen_statem:call(Pid, activate).

wait_connected(Pid) ->
    wait_connected(Pid, 30000).

wait_connected(Pid, Timeout) ->
    gen_statem:call(Pid, wait_connected, Timeout).

%% @doc Client: send a request. Headers should not include Host/Content-Length
%% (they're auto-added). Returns the assigned stream id.
send_request(Pid, Method, Path, Headers, Opts) when is_map(Opts) ->
    gen_statem:call(Pid, {send_request, Method, Path, Headers, Opts}).

send_request_with_body(Pid, Method, Path, Headers, Body) ->
    gen_statem:call(Pid, {send_request, Method, Path, Headers,
                          #{body => Body, end_stream => true}}).

%% @doc Server: send a response header block. If Headers does not
%% include Content-Length or Transfer-Encoding, the caller is expected
%% to follow up with chunked send_data/4 + send_trailers/3 / send_data
%% with end_stream=true.
send_response(Pid, StreamId, Status, Headers) ->
    gen_statem:call(Pid, {send_response, StreamId, Status, Headers, #{}}).

send_data(Pid, StreamId, Data) ->
    send_data(Pid, StreamId, Data, false).

send_data(Pid, StreamId, Data, EndStream) ->
    gen_statem:call(Pid, {send_data, StreamId, Data, EndStream}).

send_trailers(Pid, StreamId, Trailers) ->
    gen_statem:call(Pid, {send_trailers, StreamId, Trailers}).

%% @doc Server: emit a 100 Continue informational response.
continue(Pid, StreamId) ->
    gen_statem:call(Pid, {continue, StreamId}).

%% @doc Client: send an Upgrade request and block until either 101 arrives
%% (returning the raw socket) or a non-101 response is received.
upgrade(Pid, Protocol, Headers) ->
    upgrade(Pid, Protocol, Headers, 30000).

upgrade(Pid, Protocol, Headers, Timeout) ->
    gen_statem:call(Pid, {upgrade, Protocol, Headers}, Timeout).

%% @doc Server: reply to an upgrade request. Extra headers are added to the
%% 101 response; `Connection: upgrade' + `Upgrade: <token>' are auto-added.
accept_upgrade(Pid, StreamId, ExtraHeaders) ->
    gen_statem:call(Pid, {accept_upgrade, StreamId, ExtraHeaders}).

%% @doc Server: reply 200 Connection Established to a classic HTTP/1.1
%% CONNECT and take ownership of the raw socket in one step. `ExtraHeaders'
%% are written as-is; no Connection/Upgrade/framing headers are injected,
%% so bytes after the terminating CRLF belong to the tunnel.
accept_connect(Pid, StreamId, ExtraHeaders) ->
    gen_statem:call(Pid, {accept_connect, StreamId, ExtraHeaders}).

accept_connect(Pid, StreamId, ExtraHeaders, Timeout) ->
    gen_statem:call(Pid, {accept_connect, StreamId, ExtraHeaders}, Timeout).

%% @doc Abort a stream. Because H1 has no RST_STREAM equivalent, this
%% advertises `Connection: close' and closes the socket once the current
%% exchange is drained.
cancel_stream(Pid, StreamId) ->
    cancel_stream(Pid, StreamId, cancel).

cancel_stream(Pid, StreamId, Reason) ->
    gen_statem:call(Pid, {cancel_stream, StreamId, Reason}).

%% @doc Advertise Connection: close on the next response (server) or on
%% the next request (client), then shut the socket.
send_goaway(Pid) ->
    send_goaway(Pid, no_error).

send_goaway(Pid, Reason) ->
    gen_statem:call(Pid, {send_goaway, Reason}).

set_stream_handler(Pid, StreamId, Handler) ->
    set_stream_handler(Pid, StreamId, Handler, #{}).

set_stream_handler(Pid, StreamId, Handler, Opts) ->
    gen_statem:call(Pid, {set_stream_handler, StreamId, Handler, Opts}).

unset_stream_handler(Pid, StreamId) ->
    gen_statem:call(Pid, {unset_stream_handler, StreamId}).

controlling_process(Pid, NewOwner) ->
    gen_statem:call(Pid, {controlling_process, NewOwner}).

get_settings(Pid) ->
    gen_statem:call(Pid, get_settings).

get_peer_settings(Pid) ->
    gen_statem:call(Pid, get_peer_settings).

set_pipeline(Pid, Enabled) when is_boolean(Enabled) ->
    gen_statem:call(Pid, {set_pipeline, Enabled}).

close(Pid) ->
    try gen_statem:stop(Pid, normal, 5000) of
        ok -> ok
    catch
        exit:noproc      -> ok;
        exit:{noproc, _} -> ok;
        %% Process already terminated for some other reason (e.g. peer
        %% closed the socket). Nothing to clean up; caller wanted it
        %% gone and it is.
        exit:_           -> ok
    end.

%% ----------------------------------------------------------------------------
%% gen_statem callbacks
%% ----------------------------------------------------------------------------

callback_mode() -> handle_event_function.

init({Mode, Socket, Owner, Opts}) ->
    process_flag(trap_exit, true),
    Ref = erlang:monitor(process, Owner),
    Transport = transport_of(Socket),
    ParserOpts = parser_opts_from(Mode, Opts),
    Parser = h1_parse_erl:parser(ParserOpts),
    PeerHost = case maps:get(peer_host, Opts, undefined) of
        undefined -> undefined;
        H when is_binary(H) -> H;
        H when is_list(H)   -> iolist_to_binary(H)
    end,
    State = #state{
        mode = Mode,
        socket = Socket,
        transport = Transport,
        owner = Owner,
        owner_ref = Ref,
        peer_host = PeerHost,
        parser = Parser,
        parser_opts = ParserOpts,
        idle_timeout = maps:get(idle_timeout, Opts, 300000),
        request_timeout = maps:get(request_timeout, Opts, 60000),
        pipeline_enabled = maps:get(pipeline, Opts, true),
        max_keepalive_requests = maps:get(max_keepalive_requests, Opts, 100),
        next_stream_id = 1
    },
    {ok, idle, State}.

parser_opts_from(client, Opts) -> parser_base_opts(response, Opts);
parser_opts_from(server, Opts) -> parser_base_opts(request, Opts).

parser_base_opts(Type, Opts) ->
    [Type
     | [{K, V}
        || K <- [max_line_length, max_empty_lines, max_header_name_size,
                 max_header_value_size, max_headers, max_body_size],
           V <- [maps:get(K, Opts, undefined)],
           V =/= undefined]].

transport_of(Socket) ->
    case is_tuple(Socket) andalso element(1, Socket) =:= sslsocket of
        true -> ssl;
        false -> gen_tcp
    end.

%% --- events in state `idle' -------------------------------------------------

handle_event({call, From}, activate, idle, State) ->
    State1 = set_active_once(State),
    State2 = maybe_notify_connected(State1),
    Actions = [{reply, From, ok} | idle_timeout_actions(State2)],
    {next_state, open, State2, Actions};
handle_event({call, From}, wait_connected, idle,
             #state{wait_connected_waiters = W} = State) ->
    Ref = make_ref(),
    {keep_state, State#state{wait_connected_waiters = [{From, Ref} | W]}};
handle_event({call, From}, wait_connected, _OtherState,
             #state{connected_acked = true}) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, wait_connected, _OtherState,
             #state{wait_connected_waiters = W} = State) ->
    Ref = make_ref(),
    {keep_state, State#state{wait_connected_waiters = [{From, Ref} | W]}};

%% --- socket I/O -------------------------------------------------------------

handle_event(info, {tcp, Sock, Data},
             _S, #state{socket = Sock, transport = gen_tcp} = State) ->
    handle_socket_data(Data, State);
handle_event(info, {ssl, Sock, Data},
             _S, #state{socket = Sock, transport = ssl} = State) ->
    handle_socket_data(Data, State);
handle_event(info, {tcp_closed, Sock}, _S, #state{socket = Sock} = State) ->
    handle_socket_closed(State, peer_closed);
handle_event(info, {ssl_closed, Sock}, _S, #state{socket = Sock} = State) ->
    handle_socket_closed(State, peer_closed);
handle_event(info, {tcp_error, Sock, Reason}, _S, #state{socket = Sock} = State) ->
    handle_socket_closed(State, {closed, Reason});
handle_event(info, {ssl_error, Sock, Reason}, _S, #state{socket = Sock} = State) ->
    handle_socket_closed(State, {closed, Reason});

%% --- timers -----------------------------------------------------------------

handle_event({timeout, idle}, idle, _S, State) ->
    {stop, {shutdown, idle_timeout}, State};
handle_event({timeout, request}, request, _S, State) ->
    {stop, {shutdown, request_timeout}, State};

%% --- owner lifecycle --------------------------------------------------------

handle_event(info, {'DOWN', Ref, process, _Pid, _Reason}, _S,
             #state{owner_ref = Ref} = State) ->
    {stop, {shutdown, owner_down}, State};

%% --- client: send_request ---------------------------------------------------

handle_event({call, From}, {send_request, Method, Path, Headers, Opts}, open,
             #state{mode = client} = State) ->
    handle_send_request(From, Method, Path, Headers, Opts, State);
handle_event({call, From}, {send_request, _, _, _, _}, _, #state{mode = Mode}) ->
    {keep_state_and_data, [{reply, From, {error, {bad_mode, Mode}}}]};

%% --- server: send_response --------------------------------------------------

handle_event({call, From}, {send_response, StreamId, Status, Headers, _Opts}, open,
             #state{mode = server} = State) ->
    handle_send_response(From, StreamId, Status, Headers, State);
handle_event({call, From}, {send_response, _, _, _, _}, _, #state{mode = Mode}) ->
    {keep_state_and_data, [{reply, From, {error, {bad_mode, Mode}}}]};

%% --- common: send_data / send_trailers / continue ---------------------------

handle_event({call, From}, {send_data, StreamId, Data, EndStream}, open, State) ->
    handle_send_data(From, StreamId, Data, EndStream, State);
handle_event({call, From}, {send_trailers, StreamId, Trailers}, open, State) ->
    handle_send_trailers(From, StreamId, Trailers, State);
handle_event({call, From}, {continue, StreamId}, open,
             #state{mode = server} = State) ->
    handle_continue(From, StreamId, State);
handle_event({call, From}, {continue, _StreamId}, _, _State) ->
    {keep_state_and_data, [{reply, From, {error, not_server}}]};

%% --- upgrade ---------------------------------------------------------------

handle_event({call, From}, {upgrade, Protocol, Headers}, open,
             #state{mode = client} = State) ->
    handle_client_upgrade(From, Protocol, Headers, State);
handle_event({call, From}, {accept_upgrade, StreamId, ExtraHeaders}, open,
             #state{mode = server} = State) ->
    handle_accept_upgrade(From, StreamId, ExtraHeaders, State);
handle_event({call, From}, {accept_connect, StreamId, ExtraHeaders}, open,
             #state{mode = server} = State) ->
    handle_accept_connect(From, StreamId, ExtraHeaders, State);

%% --- handler registration ---------------------------------------------------

handle_event({call, From}, {set_stream_handler, StreamId, Handler, Opts},
             _S, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            Flushed = flush_handler(Stream, Handler),
            NewStream = Stream#stream{handler = Handler, handler_opts = Opts,
                                      recv_buffer = []},
            State1 = put_stream(NewStream, State),
            {keep_state, State1, [{reply, From, {ok, Flushed}}]};
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end;
handle_event({call, From}, {unset_stream_handler, StreamId}, _S, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            State1 = put_stream(Stream#stream{handler = undefined}, State),
            {keep_state, State1, [{reply, From, ok}]};
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end;

%% --- connection control -----------------------------------------------------

handle_event({call, From}, {send_goaway, _Reason}, _S, State) ->
    State1 = State#state{close_after = true, goaway_sent = true},
    {keep_state, State1, [{reply, From, ok}]};
handle_event({call, From}, {cancel_stream, StreamId, _Reason}, _S, State) ->
    State1 = case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            emit_to_owner_or_handler(Stream,
                {stream_reset, StreamId, cancel}, State),
            put_stream(Stream#stream{state = closed, closed_reason = cancel}, State);
        error -> State
    end,
    {keep_state, State1#state{close_after = true}, [{reply, From, ok}]};

handle_event({call, From}, {controlling_process, NewOwner}, _S, State) ->
    _ = case State#state.owner_ref of
        undefined -> ok;
        OldRef -> erlang:demonitor(OldRef, [flush])
    end,
    NewRef = erlang:monitor(process, NewOwner),
    {keep_state, State#state{owner = NewOwner, owner_ref = NewRef},
     [{reply, From, ok}]};

handle_event({call, From}, get_settings, _S, _State) ->
    {keep_state_and_data, [{reply, From, #{}}]};
handle_event({call, From}, get_peer_settings, _S, _State) ->
    {keep_state_and_data, [{reply, From, #{}}]};
handle_event({call, From}, {set_pipeline, Enabled}, _S, State) ->
    {keep_state, State#state{pipeline_enabled = Enabled},
     [{reply, From, ok}]};

handle_event({call, From}, activate, open, _State) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, wait_connected, open, _State) ->
    {keep_state_and_data, [{reply, From, ok}]};

%% --- catch-all --------------------------------------------------------------

handle_event({call, From}, _Msg, _S, _State) ->
    {keep_state_and_data, [{reply, From, {error, unsupported}}]};
handle_event(_EventType, _Event, _S, _State) ->
    keep_state_and_data.

terminate(Reason, _State, #state{socket = Socket, transport = T, owner = Owner,
                                 socket_handed_off = HandedOff}) ->
    catch notify(Owner, {closed, Reason}, self()),
    case HandedOff of
        false -> catch close_socket(T, Socket);
        true  -> ok
    end,
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%% ----------------------------------------------------------------------------
%% Socket helpers
%% ----------------------------------------------------------------------------

set_active_once(#state{socket = S, transport = gen_tcp} = St) ->
    _ = inet:setopts(S, [{active, once}]),
    St;
set_active_once(#state{socket = S, transport = ssl} = St) ->
    _ = ssl:setopts(S, [{active, once}]),
    St.

set_active_false(#state{socket = S, transport = gen_tcp} = St) ->
    _ = inet:setopts(S, [{active, false}]),
    St;
set_active_false(#state{socket = S, transport = ssl} = St) ->
    _ = ssl:setopts(S, [{active, false}]),
    St.

sock_send(#state{transport = gen_tcp, socket = S}, Data) -> gen_tcp:send(S, Data);
sock_send(#state{transport = ssl,    socket = S}, Data) -> ssl:send(S, Data).

close_socket(gen_tcp, S) -> gen_tcp:close(S);
close_socket(ssl, S)     -> ssl:close(S).

maybe_notify_connected(#state{connected_acked = true} = St) -> St;
maybe_notify_connected(#state{owner = Owner,
                              wait_connected_waiters = W} = St) ->
    notify(Owner, connected, self()),
    lists:foreach(fun(From) -> gen_statem:reply(From, ok) end, W),
    St#state{connected_acked = true, wait_connected_waiters = []}.

notify(Owner, Event, Conn) ->
    Owner ! {h1, Conn, Event},
    ok.

%% Generic gen_statem timeouts. Re-emitting `{{timeout, Name}, Time, _}'
%% cancels and re-arms; `infinity' cancels without re-arming.
idle_timeout_actions(#state{idle_timeout = infinity}) ->
    [{{timeout, idle}, infinity, idle}];
idle_timeout_actions(#state{idle_timeout = Ms}) when is_integer(Ms), Ms > 0 ->
    [{{timeout, idle}, Ms, idle}];
idle_timeout_actions(_) ->
    [{{timeout, idle}, infinity, idle}].

request_timeout_actions(#state{request_timeout = infinity}) ->
    [{{timeout, request}, infinity, request}];
request_timeout_actions(#state{request_timeout = Ms}) when is_integer(Ms), Ms > 0 ->
    [{{timeout, request}, Ms, request}];
request_timeout_actions(_) ->
    [{{timeout, request}, infinity, request}].

clear_request_timeout() ->
    [{{timeout, request}, infinity, request}].

%% ----------------------------------------------------------------------------
%% Parser drive
%% ----------------------------------------------------------------------------

handle_socket_data(Data, #state{parser = P, mode = Mode} = State) ->
    case drive_parser(h1_parse_erl:execute(P, Data), State, Mode) of
        {ok, State1} ->
            Actions = idle_timeout_actions(State1)
                      ++ request_timer_actions(State1),
            {keep_state, set_active_once(State1), Actions};
        {upgrade_client, Stream, NewParser, State1} ->
            complete_client_upgrade(Stream, NewParser, State1);
        {closed, Reason, State1} ->
            handle_socket_closed(State1, Reason);
        {error, Reason, State1} ->
            {stop, {shutdown, Reason}, State1}
    end.

%% Re-arm request timer if a request is in flight, cancel otherwise.
request_timer_actions(#state{mode = client, pending = Q} = State) ->
    case queue:is_empty(Q) of
        true  -> clear_request_timeout();
        false -> request_timeout_actions(State)
    end;
request_timer_actions(#state{mode = server, current_stream = undefined}) ->
    clear_request_timeout();
request_timer_actions(#state{mode = server} = State) ->
    request_timeout_actions(State).

drive_parser({more, P}, State, _Mode) ->
    {ok, State#state{parser = P}};
drive_parser({more, P, _Buf}, State, _Mode) ->
    {ok, State#state{parser = P}};
drive_parser({error, Reason}, State, _Mode) ->
    {error, Reason, State};
drive_parser({done, Rest}, State, _Mode) ->
    after_message_done(Rest, State);
drive_parser({request, Method, URI, Version, P}, State, server) ->
    State1 = on_request(Method, URI, Version, P, State),
    drive_parser(h1_parse_erl:execute(P), State1, server);
drive_parser({response, Version, Status, _Reason, P}, State, client) ->
    State1 = on_response(Version, Status, P, State),
    drive_parser(h1_parse_erl:execute(P), State1, client);
drive_parser({header, KV, P}, State, _Mode) ->
    drive_parser(h1_parse_erl:execute(P), accumulate_header(KV, State), _Mode);
drive_parser({headers_complete, P}, State, Mode) ->
    State1 = State#state{parser = P},
    case on_headers_complete(State1, Mode) of
        {continue, State2} ->
            drive_parser(h1_parse_erl:execute(State2#state.parser), State2, Mode);
        {pause, State2}    -> {ok, State2};
        {upgrade_client, Stream, Parser, State2} ->
            {upgrade_client, Stream, Parser, State2}
    end;
drive_parser({ok, Chunk, P}, State, Mode) ->
    %% Peek ahead: if the next parser event is `{done, Rest}', this chunk
    %% is the last — mark end_stream=true so consumers don't need a
    %% separate empty-data terminator.
    case h1_parse_erl:execute(P) of
        {done, Rest} ->
            State1 = deliver_data(Chunk, true, State#state{parser = P}),
            after_message_done(Rest, mark_stream_ended(State1));
        Next ->
            State1 = deliver_data(Chunk, false, State#state{parser = P}),
            drive_parser(Next, State1, Mode)
    end;
drive_parser({trailer, KV, P}, State, Mode) ->
    State1 = accumulate_trailer(KV, State#state{parser = P}),
    drive_parser(h1_parse_erl:execute(P), State1, Mode).

%% --- request / response arrival --------------------------------------------

on_request(Method, URI, Version, P, State) ->
    {Path, _Qs} = split_path(URI),
    Id = State#state.next_stream_id,
    Stream = #stream{id = Id, state = open, method = Method,
                     path = Path, version = Version},
    State#state{parser = P,
                next_stream_id = Id + 1,
                current_stream = Id,
                streams = maps:put(Id, Stream, State#state.streams)}.

on_response(Version, Status, P, State) ->
    Id = case queue:out(State#state.pending) of
        {{value, X}, _} -> X;
        {empty, _} -> State#state.next_stream_id
    end,
    Stream = case maps:find(Id, State#state.streams) of
        {ok, S} -> S#stream{status = Status, version = Version, state = open};
        error ->
            #stream{id = Id, state = open, status = Status, version = Version}
    end,
    State#state{parser = P,
                current_stream = Id,
                streams = maps:put(Id, Stream, State#state.streams)}.

accumulate_header({Name, Value}, #state{current_stream = Id} = State)
    when Id =/= undefined ->
    case maps:find(Id, State#state.streams) of
        {ok, Stream} ->
            case State#state.mode of
                server ->
                    NStream = Stream#stream{req_headers = [{Name, Value} | Stream#stream.req_headers]},
                    put_stream(NStream, State);
                client ->
                    NStream = Stream#stream{resp_headers = [{Name, Value} | Stream#stream.resp_headers]},
                    put_stream(NStream, State)
            end;
        error -> State
    end.

accumulate_trailer({Name, Value}, #state{current_stream = Id} = State)
    when Id =/= undefined ->
    case maps:find(Id, State#state.streams) of
        {ok, Stream} ->
            Trailers = [{Name, Value} | Stream#stream.trailers],
            put_stream(Stream#stream{trailers = Trailers}, State);
        error -> State
    end.

%% Called when parser signals `headers_complete'. Inspects the parser
%% to set up body framing and emits the appropriate event.
on_headers_complete(#state{mode = server, current_stream = Id} = State, server) ->
    Stream0 = maps:get(Id, State#state.streams),
    Headers = lists:reverse(Stream0#stream.req_headers),
    Stream1 = Stream0#stream{req_headers = Headers},
    %% RFC 9110 §7.2: HTTP/1.1 requests MUST include a Host header.
    case missing_host_on_http_1_1(Stream1, Headers) of
        true ->
            State1 = send_400_missing_host(Stream1, State),
            {pause, State1};
        false ->
            on_request_headers_complete(Stream1, Headers, State, Id)
    end;
on_headers_complete(#state{mode = client, current_stream = Id} = State, client) ->
    Stream0 = maps:get(Id, State#state.streams),
    Headers = lists:reverse(Stream0#stream.resp_headers),
    Stream1 = Stream0#stream{resp_headers = Headers},
    Status = Stream1#stream.status,
    case Status of
        100 ->
            %% Informational 100 Continue. Release any staged body.
            Stream2 = Stream1#stream{resp_headers = [], status = undefined},
            State1 = maybe_flush_pending_body(Id, put_stream(Stream2, State)),
            notify(State1#state.owner,
                   {informational, Id, Status, Headers}, self()),
            {continue, reset_parser_for_response(State1, Id)};
        101 ->
            {upgrade_client, Stream1, State#state.parser, put_stream(Stream1, State)};
        _ when Status >= 100, Status =< 199 ->
            Stream2 = Stream1#stream{resp_headers = [], status = undefined},
            State1 = put_stream(Stream2, State),
            notify(State1#state.owner,
                   {informational, Id, Status, Headers}, self()),
            {continue, reset_parser_for_response(State1, Id)};
        _ ->
            State1 = put_stream(Stream1, State),
            emit_to_owner_or_handler_lookup(Id,
                {response, Id, Status, Headers}, State1),
            State2 = apply_peer_connection_policy(State1, Headers,
                        Stream1#stream.version),
            {continue, State2}
    end.

on_request_headers_complete(Stream1, Headers, State, Id) ->
    case detect_upgrade(State#state.parser, Headers) of
        {upgrade, Proto} ->
            Stream2 = Stream1#stream{state = half_closed_remote},
            State1 = put_stream(Stream2, State),
            notify(State1#state.owner,
                   {upgrade, Id, Proto, Stream1#stream.method,
                    Stream1#stream.path, Headers}, self()),
            {pause, State1};
        no_upgrade ->
            Expect = h1_parse_erl:get(State#state.parser, expect),
            HasExpect = Expect =:= <<"100-continue">>,
            Stream2 = Stream1#stream{expect_continue = HasExpect},
            State1 = put_stream(Stream2, State),
            notify(State1#state.owner,
                   {request, Id, Stream1#stream.method,
                    Stream1#stream.path, Headers}, self()),
            State2 = apply_peer_connection_policy(State1, Headers,
                        Stream1#stream.version),
            {continue, State2}
    end.

missing_host_on_http_1_1(#stream{version = {1, 1}}, Headers) ->
    lookup_ci(<<"host">>, Headers) =:= undefined;
missing_host_on_http_1_1(_, _) ->
    false.

send_400_missing_host(#stream{id = Id} = Stream, State) ->
    Body = <<"Bad Request: missing Host header">>,
    Wire = [h1_message:status_line(400, ?HTTP_1_1),
            h1_message:headers([{<<"content-length">>,
                                 integer_to_binary(byte_size(Body))},
                                {<<"connection">>, <<"close">>},
                                {<<"content-type">>, <<"text/plain">>}]),
            <<"\r\n">>, Body],
    _ = sock_send(State, Wire),
    State1 = put_stream(Stream#stream{state = closed,
                                      closed_reason = bad_request}, State),
    State1#state{close_after = true, current_stream = undefined,
                 streams = maps:remove(Id, State1#state.streams)}.

detect_upgrade(Parser, Headers) ->
    Upgrade = h1_parse_erl:get(Parser, upgrade),
    Conn = h1_parse_erl:get(Parser, connection),
    case {Upgrade, has_token(Conn, <<"upgrade">>)} of
        {U, true} when is_binary(U) -> {upgrade, U};
        _ -> detect_upgrade_from_headers(Headers)
    end.

detect_upgrade_from_headers(Headers) ->
    case {lookup_ci(<<"upgrade">>, Headers), lookup_ci(<<"connection">>, Headers)} of
        {undefined, _} -> no_upgrade;
        {Upgrade, Conn} ->
            case has_token(case is_binary(Conn) of
                              true  -> h1_parse_erl:to_lower(Conn);
                              false -> undefined
                          end, <<"upgrade">>) of
                true -> {upgrade, h1_parse_erl:to_lower(Upgrade)};
                false -> no_upgrade
            end
    end.

lookup_ci(Needle, Headers) ->
    Lower = h1_parse_erl:to_lower(Needle),
    case lists:search(
           fun({N, _V}) -> h1_parse_erl:to_lower(N) =:= Lower end,
           Headers) of
        {value, {_, V}} -> iolist_to_binary(V);
        false -> undefined
    end.

has_token(undefined, _) -> false;
has_token(Header, Token) ->
    Parts = [h1_parse_erl:trim(P)
             || P <- binary:split(Header, <<",">>, [global])],
    lists:member(Token, Parts).

apply_peer_connection_policy(State, Headers, Version) ->
    Close = case lookup_ci(<<"connection">>, Headers) of
        undefined -> Version =:= ?HTTP_1_0;
        Conn ->
            Lowered = h1_parse_erl:to_lower(Conn),
            case has_token(Lowered, <<"close">>) of
                true -> true;
                false ->
                    case Version of
                        ?HTTP_1_1 -> false;
                        ?HTTP_1_0 -> not has_token(Lowered, <<"keep-alive">>);
                        _ -> true
                    end
            end
    end,
    State#state{keepalive = not Close,
                close_after = State#state.close_after orelse Close}.

deliver_data(Chunk, EndStream, #state{current_stream = Id} = State)
    when Id =/= undefined ->
    emit_to_owner_or_handler_lookup(Id, {data, Id, Chunk, EndStream}, State);
deliver_data(_Chunk, _EndStream, State) ->
    State.

emit_to_owner_or_handler_lookup(Id, Event, State) ->
    case maps:find(Id, State#state.streams) of
        {ok, Stream} -> emit_to_owner_or_handler(Stream, Event, State);
        error ->
            notify(State#state.owner, Event, self()),
            State
    end.

emit_to_owner_or_handler(#stream{handler = undefined}, Event,
                         #state{owner = Owner} = State) ->
    notify(Owner, Event, self()),
    State;
emit_to_owner_or_handler(#stream{handler = Pid} = Stream, Event, State)
    when is_pid(Pid) ->
    case should_buffer(Event) of
        true ->
            Stream1 = Stream#stream{recv_buffer =
                [Event | Stream#stream.recv_buffer]},
            put_stream(Stream1, State);
        false ->
            Pid ! {h1, self(), Event},
            State
    end.

%% For simplicity we never buffer when a handler is already set — data
%% is always delivered immediately. Buffering is only useful for the
%% window between stream creation and handler registration; callers that
%% need backpressure should use blocking send_data.
should_buffer(_) -> false.

flush_handler(#stream{recv_buffer = []}, _Handler) -> [];
flush_handler(#stream{recv_buffer = Buf} = _Stream, Handler)
    when is_pid(Handler) ->
    Events = lists:reverse(Buf),
    lists:foreach(fun(E) -> Handler ! {h1, self(), E} end, Events),
    Events.

after_message_done(Rest, #state{mode = server, current_stream = Id} = State) ->
    State1 = finalize_request(Id, State),
    State2 = State1#state{parser = reset_parser(State1), current_stream = undefined},
    case byte_size(Rest) > 0 of
        true -> drive_parser(h1_parse_erl:execute(State2#state.parser, Rest), State2, server);
        false -> {ok, State2}
    end;
after_message_done(Rest, #state{mode = client, current_stream = Id} = State) ->
    State1 = finalize_response(Id, State),
    State2 = State1#state{parser = reset_parser(State1), current_stream = undefined},
    case byte_size(Rest) > 0 of
        true -> drive_parser(h1_parse_erl:execute(State2#state.parser, Rest), State2, client);
        false -> {ok, State2}
    end.

finalize_request(Id, State) ->
    case maps:find(Id, State#state.streams) of
        {ok, Stream} ->
            State1 = emit_trailers_if_any(Id, Stream, State),
            Stream0 = maps:get(Id, State1#state.streams, Stream),
            State2 = case Stream0#stream.recv_ended orelse Stream0#stream.state =:= closed of
                true -> State1;
                false ->
                    emit_to_owner_or_handler(Stream0,
                        {data, Id, <<>>, true}, State1)
            end,
            Stream1 = (maps:get(Id, State2#state.streams, Stream0))#stream{
                state = half_closed_remote, recv_ended = true},
            State3 = put_stream(Stream1, State2),
            State3#state{requests_served = State3#state.requests_served + 1};
        error -> State
    end.

finalize_response(Id, State) ->
    State0 = case maps:find(Id, State#state.streams) of
        {ok, Stream0} -> emit_trailers_if_any(Id, Stream0, State);
        error -> State
    end,
    State1 = case maps:find(Id, State0#state.streams) of
        {ok, #stream{recv_ended = true}} -> State0;
        {ok, Stream} ->
            emit_to_owner_or_handler(Stream, {data, Id, <<>>, true}, State0);
        error -> State0
    end,
    State2 = State1#state{
        streams = maps:remove(Id, State1#state.streams),
        pending = dequeue_id(Id, State1#state.pending)
    },
    case State2#state.close_after of
        true -> State2;
        false ->
            case State2#state.requests_served + 1 >= State2#state.max_keepalive_requests of
                true -> State2#state{close_after = true};
                false -> State2#state{requests_served = State2#state.requests_served + 1}
            end
    end.

emit_trailers_if_any(_Id, #stream{trailers = []}, State) -> State;
emit_trailers_if_any(Id, #stream{trailers = Trs} = Stream, State) ->
    Ordered = lists:reverse(Trs),
    State1 = emit_to_owner_or_handler(Stream, {trailers, Id, Ordered}, State),
    Stream1 = (maps:get(Id, State1#state.streams, Stream))#stream{
        trailers = [], recv_ended = true},
    put_stream(Stream1, State1).

mark_stream_ended(#state{current_stream = Id} = State) when Id =/= undefined ->
    case maps:find(Id, State#state.streams) of
        {ok, S} -> put_stream(S#stream{recv_ended = true}, State);
        error -> State
    end;
mark_stream_ended(State) -> State.

dequeue_id(Id, Q) ->
    case queue:out(Q) of
        {{value, Id}, Q1} -> Q1;
        {{value, Other}, Q1} -> queue:in_r(Other, dequeue_id(Id, Q1));
        {empty, Q} -> Q
    end.

reset_parser(#state{mode = server, parser_opts = Opts}) ->
    h1_parse_erl:parser(Opts);
reset_parser(#state{mode = client, parser_opts = Opts, pending = Q, streams = Streams}) ->
    %% If we're about to read the next response on a pipelined connection,
    %% seed the parser with the request method of the next in-flight request
    %% so HEAD responses are handled correctly.
    Method = case queue:peek(Q) of
        {value, NextId} ->
            case maps:find(NextId, Streams) of
                {ok, #stream{method = M}} when is_binary(M) -> M;
                _ -> undefined
            end;
        empty -> undefined
    end,
    Opts1 = case Method of
        undefined -> Opts;
        _ -> [{method, Method} | Opts]
    end,
    h1_parse_erl:parser(Opts1).

reset_parser_for_response(State, Id) ->
    State#state{parser = reset_parser(State), current_stream = Id}.

%% ----------------------------------------------------------------------------
%% Client: send_request
%% ----------------------------------------------------------------------------

handle_send_request(From, Method, Path, Headers, Opts,
                    #state{pipeline_enabled = false, pending = Q} = State) ->
    case queue:is_empty(Q) of
        false -> {keep_state_and_data,
                  [{reply, From, {error, pipeline_disabled}}]};
        true  ->
            handle_send_request_ok(From, Method, Path,
                                   inject_host(Headers, State), Opts, State)
    end;
handle_send_request(From, Method, Path, Headers, Opts, State) ->
    handle_send_request_ok(From, Method, Path,
                           inject_host(Headers, State), Opts, State).

inject_host(Headers, #state{mode = client, peer_host = Host})
    when is_binary(Host), Host =/= <<>> ->
    case lookup_ci(<<"host">>, Headers) of
        undefined -> [{<<"host">>, Host} | Headers];
        _         -> Headers
    end;
inject_host(Headers, _State) ->
    Headers.

handle_send_request_ok(From, Method, Path, Headers, Opts, State) ->
    Id = State#state.next_stream_id,
    Body = maps:get(body, Opts, no_body),
    EndStream = maps:get(end_stream, Opts, Body =/= no_body),
    {Framing, Headers1} = case h1_message:choose_framing(
            case Body of no_body -> no_body; _ -> Body end, Headers) of
        {content_length, _N, Hs} -> {content_length, Hs};
        {chunked, Hs}            -> {chunked, Hs};
        {no_body, Hs}            -> {no_body, Hs}
    end,
    WantsContinue = case lookup_ci(<<"expect">>, Headers1) of
        undefined -> false;
        V -> has_token(h1_parse_erl:to_lower(V), <<"100-continue">>)
    end,
    Line = h1_message:request_line(Method, Path, ?HTTP_1_1),
    Hdrs = h1_message:headers(Headers1),
    HeaderWire = [Line, Hdrs, <<"\r\n">>],
    {WireFirst, Pending} =
        case {Body, Framing, WantsContinue} of
            {no_body, _, _} -> {HeaderWire, undefined};
            {_, _, true} ->
                %% Stage body for after 100 Continue.
                Shape = case Framing of chunked -> chunked; _ -> identity end,
                {HeaderWire, {Body, Shape, EndStream}};
            {_, chunked, false} ->
                Tail = case EndStream of
                    true -> [h1_message:encode_chunk(Body),
                             h1_message:encode_last_chunk()];
                    false -> h1_message:encode_chunk(Body)
                end,
                {[HeaderWire, Tail], undefined};
            {_, _, false} ->
                {[HeaderWire, Body], undefined}
        end,
    case sock_send(State, WireFirst) of
        ok ->
            Stream = #stream{id = Id, state = open, method = Method,
                             path = Path, req_headers = Headers1,
                             pending_body = Pending},
            State1 = State#state{
                next_stream_id = Id + 1,
                streams = maps:put(Id, Stream, State#state.streams),
                pending = queue:in(Id, State#state.pending)
            },
            State2 = case queue:len(State1#state.pending) of
                1 -> State1#state{parser = reset_parser(State1)};
                _ -> State1
            end,
            Actions = [{reply, From, {ok, Id}}
                       | request_timeout_actions(State2)],
            {keep_state, State2, Actions};
        {error, R} ->
            {keep_state_and_data, [{reply, From, {error, R}}]}
    end.

%% When a 100 Continue arrives on a stream with a pending body, release it.
maybe_flush_pending_body(Id, State) ->
    case maps:find(Id, State#state.streams) of
        {ok, #stream{pending_body = {Body, chunked, EndStream}} = S} ->
            Tail = case EndStream of
                true -> [h1_message:encode_chunk(Body),
                         h1_message:encode_last_chunk()];
                false -> h1_message:encode_chunk(Body)
            end,
            _ = sock_send(State, Tail),
            put_stream(S#stream{pending_body = undefined}, State);
        {ok, #stream{pending_body = {Body, identity, _End}} = S} ->
            _ = sock_send(State, Body),
            put_stream(S#stream{pending_body = undefined}, State);
        _ ->
            State
    end.

%% ----------------------------------------------------------------------------
%% Server: send_response, send_data, send_trailers, continue
%% ----------------------------------------------------------------------------

handle_send_response(From, StreamId, Status, Headers, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            Framing = framing_of_response(Headers),
            HeadersWire = augment_response_headers(Headers, Framing, State),
            Stream1 = Stream#stream{status = Status, resp_headers = Headers,
                                    resp_framing = Framing, state = open},
            Wire = [h1_message:status_line(Status, ?HTTP_1_1),
                    h1_message:headers(HeadersWire),
                    <<"\r\n">>],
            case sock_send(State, Wire) of
                ok ->
                    State1 = put_stream(Stream1, State),
                    {keep_state, State1, [{reply, From, ok}]};
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

augment_response_headers(Headers, chunked, State) ->
    H1 = case lookup_ci(<<"transfer-encoding">>, Headers) of
        undefined -> Headers ++ [{<<"transfer-encoding">>, <<"chunked">>}];
        _ -> Headers
    end,
    ensure_close_header(H1, State);
augment_response_headers(Headers, _, State) ->
    ensure_close_header(Headers, State).

framing_of_response(Headers) ->
    case {lookup_ci(<<"content-length">>, Headers),
          lookup_ci(<<"transfer-encoding">>, Headers)} of
        {undefined, undefined} -> chunked;
        {undefined, TE} ->
            case has_token(h1_parse_erl:to_lower(TE), <<"chunked">>) of
                true -> chunked;
                false -> chunked   %% degrade: if TE present but not chunked, still chunked
            end;
        {CL, _} ->
            case h1_parse_erl:to_int(CL) of
                {ok, N} -> {content_length, N};
                false -> {content_length, 0}
            end
    end.

ensure_close_header(Headers, #state{close_after = true}) ->
    case lookup_ci(<<"connection">>, Headers) of
        undefined -> Headers ++ [{<<"connection">>, <<"close">>}];
        _ -> Headers
    end;
ensure_close_header(Headers, _State) ->
    Headers.

handle_send_data(From, StreamId, Data, EndStream, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            Wire = frame_body(Stream, Data, EndStream),
            case sock_send(State, Wire) of
                ok ->
                    Stream1 = case EndStream of
                        true -> Stream#stream{state = half_closed_local};
                        false -> Stream
                    end,
                    State1 = put_stream(Stream1, State),
                    State2 = maybe_close_server_stream(StreamId, State1),
                    case EndStream andalso State2#state.close_after
                         andalso State2#state.mode =:= server of
                        true ->
                            {stop_and_reply,
                             {shutdown, goaway_sent},
                             [{reply, From, ok}],
                             State2};
                        false ->
                            {keep_state, State2, [{reply, From, ok}]}
                    end;
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

frame_body(#stream{resp_framing = chunked}, Data, EndStream) ->
    Chunk = h1_message:encode_chunk(Data),
    case EndStream of
        true -> [Chunk, h1_message:encode_last_chunk()];
        false -> Chunk
    end;
frame_body(#stream{resp_framing = {content_length, _}}, Data, _EndStream) ->
    Data;
frame_body(#stream{resp_framing = no_body}, _Data, _EndStream) ->
    <<>>;
frame_body(#stream{}, Data, _EndStream) ->
    Data.

maybe_close_server_stream(StreamId, #state{mode = server} = State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{state = half_closed_local} = S} ->
            %% Response done. If request body also done we can drop the stream.
            put_stream(S#stream{state = closed}, State);
        _ -> State
    end;
maybe_close_server_stream(_, State) -> State.

handle_send_trailers(From, StreamId, Trailers, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{resp_framing = chunked} = Stream} ->
            Wire = h1_message:encode_last_chunk(Trailers),
            case sock_send(State, Wire) of
                ok ->
                    State1 = put_stream(
                        Stream#stream{state = half_closed_local}, State),
                    {keep_state, State1, [{reply, From, ok}]};
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        {ok, _} ->
            {keep_state_and_data,
             [{reply, From, {error, trailers_require_chunked}}]};
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

handle_continue(From, StreamId, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{expect_continue = true, continue_sent = false} = S} ->
            Wire = [h1_message:status_line(100, ?HTTP_1_1), <<"\r\n">>],
            case sock_send(State, Wire) of
                ok ->
                    State1 = put_stream(S#stream{continue_sent = true}, State),
                    {keep_state, State1, [{reply, From, ok}]};
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        {ok, _} ->
            {keep_state_and_data, [{reply, From, {error, not_applicable}}]};
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

%% ----------------------------------------------------------------------------
%% Upgrade
%% ----------------------------------------------------------------------------

handle_client_upgrade(From, Protocol, Headers, State) ->
    %% Ensure required headers are present.
    Hs0 = upsert(<<"connection">>, <<"Upgrade">>, Headers),
    Hs1 = upsert(<<"upgrade">>, Protocol, Hs0),
    Id = State#state.next_stream_id,
    Wire = [h1_message:request_line(<<"GET">>,
                                    maps:get(path, #{}, <<"/">>), ?HTTP_1_1),
            h1_message:headers(Hs1),
            <<"\r\n">>],
    _ = Wire,
    %% The caller really wants the path in Headers; we don't try to guess.
    %% We implement upgrade by reusing send_request with method=GET.
    case sock_send(State, upgrade_wire(Hs1)) of
        ok ->
            Stream = #stream{id = Id, state = open, method = <<"GET">>,
                             upgrade_from = From,
                             upgrade_protocol = Protocol,
                             req_headers = Hs1},
            State1 = State#state{
                next_stream_id = Id + 1,
                streams = maps:put(Id, Stream, State#state.streams),
                pending = queue:in(Id, State#state.pending),
                parser = reset_parser_for_upgrade(State)
            },
            {keep_state, State1};
        {error, R} ->
            {keep_state_and_data, [{reply, From, {error, R}}]}
    end.

%% The path must be in Headers (pseudo-header style) or defaulted to "/".
upgrade_wire(Headers) ->
    Path = case lookup_ci(<<":path">>, Headers) of
        undefined -> <<"/">>;
        P -> P
    end,
    Hs = [{N, V} || {N, V} <- Headers,
                    h1_parse_erl:to_lower(iolist_to_binary(N)) =/= <<":path">>],
    [h1_message:request_line(<<"GET">>, Path, ?HTTP_1_1),
     h1_message:headers(Hs),
     <<"\r\n">>].

reset_parser_for_upgrade(#state{parser_opts = Opts}) ->
    h1_parse_erl:parser([{method, <<"GET">>} | Opts]).

complete_client_upgrade(#stream{id = Id, upgrade_from = From,
                                upgrade_protocol = Proto,
                                resp_headers = Headers} = _Stream,
                        Parser,
                        #state{} = State) ->
    Buffer = h1_parse_erl:get(Parser, buffer),
    State1 = set_active_false(State),
    {FromPid, _} = From,
    _ = case State1#state.transport of
        gen_tcp -> gen_tcp:controlling_process(State1#state.socket, FromPid);
        ssl     -> ssl:controlling_process(State1#state.socket, FromPid)
    end,
    gen_statem:reply(From, {ok, Id, State1#state.socket, Buffer, Headers}),
    notify(State1#state.owner,
           {upgraded, Id, Proto, State1#state.socket, Buffer, Headers}, self()),
    {stop, {shutdown, upgraded}, State1#state{socket_handed_off = true}}.

handle_accept_upgrade(From, StreamId, ExtraHeaders, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{req_headers = Hs} = _Stream} ->
            Proto = case lookup_ci(<<"upgrade">>, Hs) of
                undefined -> undefined;
                P -> P
            end,
            case Proto of
                undefined ->
                    {keep_state_and_data,
                     [{reply, From, {error, no_upgrade_header}}]};
                _ ->
                    Hdrs = [{<<"connection">>, <<"Upgrade">>},
                            {<<"upgrade">>, Proto}
                            | ExtraHeaders],
                    Wire = [h1_message:status_line(101, ?HTTP_1_1),
                            h1_message:headers(Hdrs),
                            <<"\r\n">>],
                    case sock_send(State, Wire) of
                        ok ->
                            Buffer = h1_parse_erl:get(State#state.parser, buffer),
                            State1 = set_active_false(State),
                            {FromPid, _} = From,
                            _ = case State1#state.transport of
                                gen_tcp -> gen_tcp:controlling_process(State1#state.socket, FromPid);
                                ssl     -> ssl:controlling_process(State1#state.socket, FromPid)
                            end,
                            gen_statem:reply(From, {ok, State1#state.socket, Buffer}),
                            notify(State1#state.owner,
                                {upgraded, StreamId, Proto,
                                 State1#state.socket, Buffer, Hdrs}, self()),
                            {stop, {shutdown, upgraded},
                             State1#state{socket_handed_off = true}};
                        {error, R} ->
                            {keep_state_and_data,
                             [{reply, From, {error, R}}]}
                    end
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

handle_accept_connect(From, StreamId, ExtraHeaders, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{status = Status}} when Status =/= undefined ->
            {keep_state_and_data,
             [{reply, From, {error, response_already_sent}}]};
        {ok, _Stream} ->
            Wire = [h1_message:status_line(200,
                                           <<"Connection Established">>,
                                           ?HTTP_1_1),
                    h1_message:headers(ExtraHeaders),
                    <<"\r\n">>],
            case sock_send(State, Wire) of
                ok ->
                    Buffer = h1_parse_erl:get(State#state.parser, buffer),
                    State1 = set_active_false(State),
                    {FromPid, _} = From,
                    Transport = State1#state.transport,
                    Socket = State1#state.socket,
                    _ = case Transport of
                        gen_tcp -> gen_tcp:controlling_process(Socket, FromPid);
                        ssl     -> ssl:controlling_process(Socket, FromPid)
                    end,
                    gen_statem:reply(From,
                                     {ok, Transport, Socket, Buffer}),
                    notify(State1#state.owner,
                           {connected, StreamId, Transport, Socket, Buffer},
                           self()),
                    {stop, {shutdown, connected},
                     State1#state{socket_handed_off = true}};
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

upsert(Name, Value, Headers) ->
    Lower = h1_parse_erl:to_lower(iolist_to_binary(Name)),
    case lists:any(fun({N, _}) ->
                h1_parse_erl:to_lower(iolist_to_binary(N)) =:= Lower
             end, Headers) of
        true -> Headers;
        false -> Headers ++ [{Name, Value}]
    end.

put_stream(#stream{id = Id} = S, State) ->
    State#state{streams = maps:put(Id, S, State#state.streams)}.

split_path(URI) ->
    case binary:split(URI, <<"?">>) of
        [URI]  -> {URI, <<>>};
        [P, Q] -> {P, Q}
    end.

handle_socket_closed(#state{} = State0, Reason) ->
    %% RFC 9112 §6.3 item 7: a close-delimited response body is bounded
    %% by the socket close — finalize the parser and emit the final
    %% end-of-stream data event to the owner before declaring the
    %% connection closed. If the parser was in the middle of a framed
    %% body, signal truncation via `{closed, {incomplete_body, _}}'.
    State = maybe_finalize_close_delimited(State0, Reason),
    notify(State#state.owner, {closed, Reason}, self()),
    {stop, {shutdown, Reason}, State}.

maybe_finalize_close_delimited(#state{mode = client,
                                      current_stream = Id,
                                      parser = P} = State,
                               _Reason) when Id =/= undefined ->
    case h1_parse_erl:get(P, body_framing) of
        close_delimited ->
            case h1_parse_erl:finish(P) of
                {done, _} ->
                    case maps:find(Id, State#state.streams) of
                        {ok, Stream} ->
                            St1 = emit_to_owner_or_handler(
                                    Stream, {data, Id, <<>>, true}, State),
                            St2 = put_stream(
                                    Stream#stream{recv_ended = true}, St1),
                            St2;
                        error -> State
                    end;
                _ -> State
            end;
        _ -> State
    end;
maybe_finalize_close_delimited(State, _) ->
    State.
