%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
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
-export([send_response/4, respond/5, respond/6]).
-export([send_data/3, send_data/4]).
-export([send_trailers/3]).
-export([continue/2]).
-export([consume/3, release_window/2]).
-export([send_informational/4]).
-export([peername/1, peercert/1]).
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
-export([transport_of/1]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, terminate/3, code_change/4]).
-export([handle_event/4]).

-include("h1.hrl").

-type mode() :: client | server.
-type stream_id() :: non_neg_integer().
-type version() :: {non_neg_integer(), non_neg_integer()}.
-type headers() :: [{binary(), iodata()}].
-type reason() :: term().

%% Bound on the early-response inbound drain (lingering close). `disabled'
%% skips the drain and closes immediately; `{MaxBytes, MaxMs}' reads and
%% discards up to MaxBytes / MaxMs (either component `infinity') before
%% closing. See `enter_lingering_close/3'.
-type drain_budget() :: disabled
                      | {non_neg_integer() | infinity,
                         non_neg_integer() | infinity}.

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
    upgrade_from          :: undefined | gen_statem:from(),
    upgrade_protocol      :: undefined | binary(),
    closed_reason         :: undefined | reason(),
    %% Client: receive flow control for this response (`manual' waits for
    %% consume/3), and the monitor on its handler while it is `manual'.
    flow_control = auto   :: auto | manual,
    handler_mon           :: undefined | reference()
}).

-record(state, {
    mode                   :: mode(),
    socket,
    transport              :: gen_tcp | ssl,
    owner                  :: pid(),
    owner_ref              :: reference(),
    peer                   :: {inet:ip_address(), inet:port_number()} | undefined,
    %% Certificate the peer presented in the TLS handshake, read once at
    %% start so it does not depend on the socket afterwards.
    peercert = {error, closed} :: {ok, binary()} | {error, term()},
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
    %% Bound on the lingering-close drain (server): read and discard an
    %% unfinished request body after an early response, up to this
    %% {MaxBytes, MaxMs} budget, before closing the socket. See the
    %% `lingering_close' state and `enter_lingering_close/3'.
    drain_budget = {infinity, 30000} :: drain_budget(),
    %% Bytes still allowed to be discarded during the current drain
    %% (set from the budget on entering `lingering_close').
    drain_left             :: undefined | non_neg_integer() | infinity,
    %% Upgrade handoff (synchronous server-side accept).
    upgrade_accept         :: undefined | {pid(), reference(), stream_id()},
    %% Shutdown policy. `close_after': close once the response in progress
    %% is done (goaway, cancel, parse error, early response).
    close_after = false    :: boolean(),
    goaway_sent = false    :: boolean(),
    %% Server: the stream whose response is the last on this connection,
    %% set by a request or a response carrying `Connection: close'
    %% (RFC 9112 §9.6). Once its request is read, later input is discarded.
    close_stream           :: undefined | stream_id(),
    reading = parse        :: parse | discard,
    %% Server: input past the last request was read or discarded, so the
    %% close must be staged (lingering close) to avoid a reset.
    unread = false         :: boolean(),
    discarded = 0          :: non_neg_integer(),
    %% Connection lifecycle.
    connected_acked = false :: boolean(),
    wait_connected_waiters = [] :: [gen_statem:from()],
    %% True once the socket has been controlling_process'd to someone else
    %% (after a successful Upgrade). terminate/3 must not close it then.
    socket_handed_off = false :: boolean(),
    %% Server: an Upgrade/CONNECT request is awaiting accept_upgrade/
    %% accept_connect. While true the socket stays passive so bytes that
    %% belong to the tunnel are not parsed as HTTP.
    upgrade_pending = false :: boolean(),
    %% Server: receive-side flow control for request bodies. In `manual'
    %% mode the socket is not re-armed once `recv_unconsumed' body bytes of
    %% the current request reach `recv_window'; consume/3 gives credit back.
    %% `recv_flow' is the mode of the request being read (`auto' between
    %% requests and once the window is released).
    flow_control = auto    :: auto | manual,
    recv_window = 65536    :: pos_integer(),
    recv_flow = auto       :: auto | manual,
    recv_unconsumed = 0    :: non_neg_integer(),
    recv_paused = false    :: boolean(),
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
%% with end_stream=true. A response to HEAD, a 204 or a 304 gets no body
%% framing and no body bytes; a 1xx is sent as an interim response.
send_response(Pid, StreamId, Status, Headers) ->
    gen_statem:call(Pid, {send_response, StreamId, Status, Headers, #{}}).

%% @doc Server: send a complete response (status, headers, body) in one
%% socket write and end the stream.
respond(Pid, StreamId, Status, Headers, Body) ->
    respond(Pid, StreamId, Status, Headers, Body, #{}).

%% @doc As respond/5, with per-response options. `early_response_drain'
%% overrides the listener's early-response drain budget for this response
%% (see drain_budget_from_opts/1 for accepted forms).
respond(Pid, StreamId, Status, Headers, Body, Opts) when is_map(Opts) ->
    gen_statem:call(Pid, {respond, StreamId, Status, Headers, Body, Opts}).

send_data(Pid, StreamId, Data) ->
    send_data(Pid, StreamId, Data, false).

send_data(Pid, StreamId, Data, EndStream) ->
    gen_statem:call(Pid, {send_data, StreamId, Data, EndStream}).

send_trailers(Pid, StreamId, Trailers) ->
    gen_statem:call(Pid, {send_trailers, StreamId, Trailers}).

%% @doc Server: give back `Bytes' of request body credit on a connection
%% started with `flow_control => manual'. Counts body payload only. A no-op
%% returning `ok' in `auto' mode; `{error, unknown_stream}' once the body of
%% `StreamId' has ended or it is not the request being read.
consume(Pid, StreamId, Bytes) when is_integer(Bytes), Bytes >= 0 ->
    %% A consumer still reading queued chunks after the connection ended
    %% (the peer closed, a close-delimited body finished) is normal: the
    %% stream is over, so say so rather than exit the caller.
    try gen_statem:call(Pid, {consume, StreamId, Bytes})
    catch exit:{Reason, _} when Reason =:= noproc; Reason =:= normal;
                                Reason =:= shutdown ->
              {error, unknown_stream};
          exit:{{shutdown, _}, _} ->
              {error, unknown_stream}
    end.

%% @doc Server: stop applying the receive window to the request body of
%% `StreamId', for example because its handler is gone. Reading resumes if
%% it was paused. Asynchronous; a no-op in `auto' mode.
release_window(Pid, StreamId) ->
    gen_statem:cast(Pid, {release_window, StreamId}).

%% @doc Server: emit a 100 Continue informational response.
continue(Pid, StreamId) ->
    gen_statem:call(Pid, {continue, StreamId}).

%% @doc Server: emit an interim (1xx) response, e.g. 103 Early Hints,
%% before the final response. May be called multiple times per stream.
%% 101 is rejected (that is the Upgrade path), as is any call after the
%% final response headers went out, or to an HTTP/1.0 client (RFC 9110
%% §15.2 forbids 1xx to HTTP/1.0).
send_informational(Pid, StreamId, Status, Headers) ->
    gen_statem:call(Pid, {send_informational, StreamId, Status, Headers}).

%% @doc Address and port of the connected peer, recorded when the
%% connection process started.
peername(Pid) ->
    gen_statem:call(Pid, peername).

%% @doc DER certificate the peer presented in the TLS handshake, recorded
%% when the connection process started. `{error, no_peercert}' over plain
%% TCP or when the peer sent none; `{error, closed}' once the connection
%% process is gone (for example after the socket was handed over).
peercert(Pid) ->
    try gen_statem:call(Pid, peercert)
    catch exit:{Reason, _} when Reason =:= noproc; Reason =:= normal;
                                Reason =:= shutdown ->
              {error, closed};
          exit:{{shutdown, _}, _} ->
              {error, closed}
    end.

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
    Peer = case sock_peername(Transport, Socket) of
        {ok, P} -> P;
        {error, _} -> undefined
    end,
    State = #state{
        mode = Mode,
        socket = Socket,
        transport = Transport,
        owner = Owner,
        owner_ref = Ref,
        peer = Peer,
        peercert = sock_peercert(Transport, Socket),
        peer_host = PeerHost,
        parser = Parser,
        parser_opts = ParserOpts,
        idle_timeout = maps:get(idle_timeout, Opts, 300000),
        request_timeout = maps:get(request_timeout, Opts, 60000),
        drain_budget = drain_budget_from_opts(Opts),
        flow_control = flow_control_from_opts(Opts),
        recv_window = recv_window_from_opts(Opts),
        pipeline_enabled = maps:get(pipeline, Opts, true),
        max_keepalive_requests = maps:get(max_keepalive_requests, Opts, 100),
        next_stream_id = 1
    },
    {ok, idle, State}.

flow_control_from_opts(Opts) ->
    case maps:get(flow_control, Opts, auto) of
        auto -> auto;
        manual -> manual
    end.

recv_window_from_opts(Opts) ->
    case maps:get(recv_window, Opts, 65536) of
        N when is_integer(N), N > 0 -> N
    end.

parser_opts_from(client, Opts) -> parser_base_opts(response, Opts);
parser_opts_from(server, Opts) -> parser_base_opts(request, Opts).

%% Connection-level default drain budget. `early_response_drain' takes
%% precedence; `lingering_timeout' is the legacy time-only form
%% (`{infinity, Ms}'); otherwise the 30 s default applies.
drain_budget_from_opts(Opts) ->
    case maps:find(early_response_drain, Opts) of
        {ok, B}  -> normalize_drain_budget(B);
        error ->
            case maps:find(lingering_timeout, Opts) of
                {ok, Ms} -> normalize_drain_budget({infinity, Ms});
                error    -> {infinity, 30000}
            end
    end.

%% Resolve the budget for one early response: a per-call
%% `early_response_drain' (respond/6) overrides the connection default.
drain_budget_for(Opts, Default) ->
    case maps:find(early_response_drain, Opts) of
        {ok, B} -> normalize_drain_budget(B);
        error   -> Default
    end.

%% Accepted forms: `0' / `disabled' disable the drain; `{MaxBytes, MaxMs}'
%% bounds it (either component a non-negative integer or `infinity'). A zero
%% component also disables, since it would close before discarding anything.
normalize_drain_budget(0) -> disabled;
normalize_drain_budget(disabled) -> disabled;
normalize_drain_budget({0, _}) -> disabled;
normalize_drain_budget({_, 0}) -> disabled;
normalize_drain_budget({B, M} = Budget)
  when (B =:= infinity orelse (is_integer(B) andalso B > 0)),
       (M =:= infinity orelse (is_integer(M) andalso M > 0)) ->
    Budget.

parser_base_opts(Type, Opts) ->
    [Type
     | [{K, V}
        || K <- [max_line_length, max_request_line_size, max_empty_lines,
                 max_header_name_size, max_header_value_size, max_headers,
                 max_header_block_size, max_body_size],
           V <- [maps:get(K, Opts, undefined)],
           V =/= undefined]].

%% @doc Transport module for a socket. `h1_connection' infers it from the
%% socket itself; `h1_server' and `h1:serve_socket/2' need the same atom for
%% their own close/transfer dispatch.
-spec transport_of(term()) -> gen_tcp | ssl.
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
    {keep_state, State#state{wait_connected_waiters = [From | W]}};
handle_event({call, From}, wait_connected, _OtherState,
             #state{connected_acked = true}) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, wait_connected, _OtherState,
             #state{wait_connected_waiters = W} = State) ->
    {keep_state, State#state{wait_connected_waiters = [From | W]}};

%% --- receive flow control (server) ------------------------------------------
%% Handled in every state, ahead of the lingering-close catch-all: once the
%% connection drains, the body is finished and consume/3 says so.

handle_event({call, From}, {consume, StreamId, Bytes}, _S,
             #state{mode = client} = State) ->
    {Reply, State1} = client_consume(StreamId, Bytes, State),
    {keep_state, State1, [{reply, From, Reply}]};
handle_event({call, From}, {consume, _StreamId, _Bytes}, _S,
             #state{flow_control = auto}) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, {consume, StreamId, Bytes}, S, State)
  when S =/= lingering_close ->
    case window_stream(StreamId, State) of
        true ->
            U = max(0, State#state.recv_unconsumed - Bytes),
            State1 = maybe_resume(State#state{recv_unconsumed = U}),
            {keep_state, State1, [{reply, From, ok}]};
        false ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end;
handle_event({call, From}, {consume, _StreamId, _Bytes}, lingering_close,
             _State) ->
    {keep_state_and_data, [{reply, From, {error, unknown_stream}}]};
handle_event(cast, {release_window, StreamId}, S, State)
  when S =/= lingering_close ->
    {keep_state, release_window_of(StreamId, State)};

%% --- lingering close --------------------------------------------------------
%% After an early response (request body not fully received) we drain and
%% discard inbound bytes until the peer closes, the byte budget is spent, or
%% the linger timer fires, then close. Discarded raw, never parsed, so a large
%% leftover body cannot trip the body-size cap and RST the socket before the
%% client reads the response.

handle_event(info, {tcp, Sock, Data}, lingering_close,
             #state{socket = Sock, transport = gen_tcp} = State) ->
    drain_discard(Data, State);
handle_event(info, {ssl, Sock, Data}, lingering_close,
             #state{socket = Sock, transport = ssl} = State) ->
    drain_discard(Data, State);
handle_event(info, {tcp_closed, Sock}, lingering_close,
             #state{socket = Sock} = State) ->
    {stop, {shutdown, closed}, State};
handle_event(info, {ssl_closed, Sock}, lingering_close,
             #state{socket = Sock} = State) ->
    {stop, {shutdown, closed}, State};
handle_event(info, {tcp_error, Sock, _R}, lingering_close,
             #state{socket = Sock} = State) ->
    {stop, {shutdown, closed}, State};
handle_event(info, {ssl_error, Sock, _R}, lingering_close,
             #state{socket = Sock} = State) ->
    {stop, {shutdown, closed}, State};
handle_event({timeout, linger}, linger, lingering_close, State) ->
    {stop, {shutdown, lingering_timeout}, State};
handle_event({call, From}, _Msg, lingering_close, _State) ->
    %% The stream is finished and the connection is closing.
    {keep_state_and_data, [{reply, From, {error, closed}}]};

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
handle_event(info, {'DOWN', Ref, process, _Pid, _Reason}, _S,
             #state{mode = client} = State) ->
    %% The handler of a `manual' response is gone: nobody will consume, so
    %% release the window instead of leaving the socket paused.
    {keep_state, handler_down(Ref, State)};

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

handle_event({call, From}, {respond, StreamId, Status, Headers, Body, Opts}, open,
             #state{mode = server} = State) ->
    handle_respond(From, StreamId, Status, Headers, Body, Opts, State);
handle_event({call, From}, {respond, _, _, _, _, _}, _, #state{mode = Mode}) ->
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
handle_event({call, From}, {send_informational, StreamId, Status, Headers}, open,
             #state{mode = server} = State) ->
    handle_send_informational(From, StreamId, Status, Headers, State);
handle_event({call, From}, {send_informational, _, _, _}, _, _State) ->
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
            State1 = client_stream_flow(NewStream, Opts,
                                        put_stream(NewStream, State)),
            {keep_state, State1, [{reply, From, {ok, Flushed}}]};
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end;
handle_event({call, From}, {unset_stream_handler, StreamId}, _S, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            State1 = put_stream(demonitor_handler(Stream#stream{handler = undefined}),
                                State),
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
            _ = emit_to_owner_or_handler(Stream,
                {stream_reset, StreamId, cancel}, State),
            put_stream(Stream#stream{state = closed, closed_reason = cancel}, State);
        error -> State
    end,
    %% A cancelled request must not leave the socket paused by its window.
    State2 = release_window_of(StreamId, State1),
    {keep_state, State2#state{close_after = true}, [{reply, From, ok}]};

handle_event({call, From}, {controlling_process, NewOwner}, _S, State) ->
    _ = erlang:demonitor(State#state.owner_ref, [flush]),
    NewRef = erlang:monitor(process, NewOwner),
    {keep_state, State#state{owner = NewOwner, owner_ref = NewRef},
     [{reply, From, ok}]};

handle_event({call, From}, peername, _S, #state{peer = undefined}) ->
    {keep_state_and_data, [{reply, From, {error, closed}}]};
handle_event({call, From}, peername, _S, #state{peer = Peer}) ->
    {keep_state_and_data, [{reply, From, {ok, Peer}}]};
handle_event({call, From}, peercert, _S, #state{peercert = Cert}) ->
    {keep_state_and_data, [{reply, From, Cert}]};

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
    try notify(Owner, {closed, Reason}, self()) catch _:_ -> ok end,
    _ = case HandedOff of
        false -> try close_socket(T, Socket) catch _:_ -> ok end;
        true  -> ok
    end,
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%% ----------------------------------------------------------------------------
%% Socket helpers
%% ----------------------------------------------------------------------------

%% If re-arming the socket fails (typically because the peer already
%% closed it), synthesize the matching close event so the state machine
%% shuts down promptly instead of stalling until idle_timeout.
set_active_once(#state{socket = S, transport = gen_tcp} = St) ->
    case inet:setopts(S, [{active, once}]) of
        ok -> St;
        {error, _} -> self() ! {tcp_closed, S}, St
    end;
set_active_once(#state{socket = S, transport = ssl} = St) ->
    case ssl:setopts(S, [{active, once}]) of
        ok -> St;
        {error, _} -> self() ! {ssl_closed, S}, St
    end.

%% Re-arm the socket after parsing, unless the request body being read has
%% filled the receive window (`flow_control => manual'). The socket is then
%% left passive, so the kernel buffers fill and TCP holds the client back;
%% consume/3 or release_window/2 resumes reading. Only the parse path goes
%% through here: the discard and lingering-close drains re-arm directly, so
%% the window never stalls them.
rearm(#state{recv_flow = auto} = St) ->
    set_active_once(St);
rearm(St) ->
    case window_full(St) of
        true  -> St#state{recv_paused = true};
        false -> set_active_once(St#state{recv_paused = false})
    end.

window_full(#state{recv_flow = manual, reading = parse,
                   current_stream = Id, recv_unconsumed = U, recv_window = W})
  when Id =/= undefined, U >= W ->
    true;
window_full(_St) ->
    false.

%% Resume a paused socket once the window has room again.
maybe_resume(#state{recv_paused = true} = St) ->
    case window_full(St) of
        true  -> St;
        false -> set_active_once(St#state{recv_paused = false})
    end;
maybe_resume(St) ->
    St.

%% True when `StreamId' is the request whose body is being read.
window_stream(StreamId, #state{mode = server, current_stream = StreamId,
                               streams = Streams}) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{recv_ended = false}} -> true;
        _ -> false
    end;
window_stream(_StreamId, _St) ->
    false.

%% Stop counting the body of `StreamId' (its handler is gone or the stream
%% was cancelled) and resume reading if the window had paused it.
release_window_of(StreamId, #state{mode = client} = St) ->
    case maps:find(StreamId, St#state.streams) of
        {ok, #stream{flow_control = manual} = S} ->
            St1 = put_stream(demonitor_handler(S#stream{flow_control = auto}), St),
            case St1#state.current_stream of
                StreamId ->
                    maybe_resume(St1#state{recv_flow = auto, recv_unconsumed = 0});
                _ ->
                    St1
            end;
        _ ->
            St
    end;
release_window_of(StreamId, #state{recv_flow = manual} = St) ->
    case window_stream(StreamId, St) of
        true  -> maybe_resume(St#state{recv_flow = auto, recv_unconsumed = 0});
        false -> St
    end;
release_window_of(_StreamId, St) ->
    St.

%% Client: consume/3 on a response. Credit applies to the response being
%% read; a `manual' stream still waiting for its response and any `auto'
%% stream take it as a no-op. A finished or unknown stream is reported.
client_consume(StreamId, Bytes, #state{current_stream = Cur,
                                       recv_flow = Flow} = St) ->
    case maps:find(StreamId, St#state.streams) of
        {ok, #stream{recv_ended = false}}
          when StreamId =:= Cur, Flow =:= manual ->
            U = max(0, St#state.recv_unconsumed - Bytes),
            {ok, maybe_resume(St#state{recv_unconsumed = U})};
        {ok, #stream{recv_ended = false}} ->
            {ok, St};
        _ ->
            {{error, unknown_stream}, St}
    end.

stream_flow(manual) -> manual;
stream_flow(_) -> auto.

%% Client: `flow_control' in set_stream_handler/4 opts switches the stream's
%% mode, as in h2. A `manual' stream's handler is monitored so its exit
%% releases the window. Server streams follow the connection's mode.
client_stream_flow(#stream{id = Id} = Stream0, Opts, #state{mode = client} = St) ->
    Flow = stream_flow(maps:get(flow_control, Opts, Stream0#stream.flow_control)),
    Stream1 = demonitor_handler(Stream0#stream{flow_control = Flow}),
    Stream = case {Flow, Stream1#stream.handler} of
        {manual, Pid} when is_pid(Pid) ->
            Stream1#stream{handler_mon = erlang:monitor(process, Pid)};
        _ ->
            Stream1
    end,
    St1 = put_stream(Stream, St),
    case St1#state.current_stream of
        Id when Flow =:= auto ->
            maybe_resume(St1#state{recv_flow = auto, recv_unconsumed = 0});
        Id when St1#state.recv_flow =:= auto ->
            %% Switched to manual mid-body: count from here.
            St1#state{recv_flow = manual, recv_unconsumed = 0};
        _ ->
            St1
    end;
client_stream_flow(_Stream, _Opts, St) ->
    St.

demonitor_handler(#stream{handler_mon = undefined} = S) ->
    S;
demonitor_handler(#stream{handler_mon = Ref} = S) ->
    _ = erlang:demonitor(Ref, [flush]),
    S#stream{handler_mon = undefined}.

handler_down(Ref, #state{streams = Streams} = St) ->
    case [Id || {Id, #stream{handler_mon = R}} <- maps:to_list(Streams), R =:= Ref] of
        [Id] ->
            S = maps:get(Id, Streams),
            release_window_of(Id, put_stream(S#stream{handler_mon = undefined}, St));
        [] ->
            St
    end.

set_active_false(St) ->
    _ = set_passive(St),
    St.

set_passive(#state{socket = S, transport = gen_tcp}) ->
    inet:setopts(S, [{active, false}]);
set_passive(#state{socket = S, transport = ssl}) ->
    ssl:setopts(S, [{active, false}]).

sock_send(#state{transport = gen_tcp, socket = S}, Data) -> gen_tcp:send(S, Data);
sock_send(#state{transport = ssl,    socket = S}, Data) -> ssl:send(S, Data).

sock_peername(gen_tcp, S) -> inet:peername(S);
sock_peername(ssl, S)     -> ssl:peername(S).

sock_peercert(gen_tcp, _S) -> {error, no_peercert};
sock_peercert(ssl, S)      -> ssl:peercert(S).

close_socket(gen_tcp, S) -> gen_tcp:close(S);
close_socket(ssl, S)     -> ssl:close(S).

%% Half-close the write side (send FIN) once the final response is on the
%% wire, so the peer learns we are done before we drain its remaining body.
sock_shutdown_write(#state{transport = gen_tcp, socket = S}) ->
    _ = gen_tcp:shutdown(S, write), ok;
sock_shutdown_write(#state{transport = ssl, socket = S}) ->
    _ = ssl:shutdown(S, write), ok.

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

handle_socket_data(Data, #state{mode = server, reading = discard} = State) ->
    discard_input(Data, State);
handle_socket_data(Data, #state{parser = P, mode = Mode} = State) ->
    case drive_parser(h1_parse_erl:execute(P, Data), State, Mode) of
        {ok, #state{upgrade_pending = true} = State1} ->
            %% A tunnel handshake is pending: keep the socket passive so
            %% post-handshake bytes are handed to the new owner intact
            %% rather than parsed as the next HTTP message.
            Actions = idle_timeout_actions(State1),
            {keep_state, set_active_false(State1), Actions};
        {ok, State1} ->
            Actions = idle_timeout_actions(State1)
                      ++ request_timer_actions(State1),
            {keep_state, rearm(State1), Actions};
        {upgrade_client, Stream, NewParser, State1} ->
            complete_client_upgrade(Stream, NewParser, State1);
        {error, Reason, State1} ->
            answer_parse_error(Reason, State1)
    end.

%% A server answers a malformed or over-limit request with the status
%% `h1_error' maps the reason to, then closes (RFC 9112 §9.6). Reasons that
%% classify as timeouts or closes, and breaches that trip after response
%% bytes are already on the wire, keep closing without an answer.
answer_parse_error(Reason, #state{mode = server} = State) ->
    case answerable(Reason, State) of
        true ->
            State1 = send_error_response(Reason, State),
            enter_lingering_close([], State1#state.drain_budget, State1);
        false ->
            {stop, {shutdown, Reason}, State}
    end;
answer_parse_error(Reason, State) ->
    {stop, {shutdown, Reason}, State}.

answerable(Reason, State) ->
    case h1_error:classify(Reason) of
        parse_error  -> not response_started(State);
        client_error -> not response_started(State);
        _            -> false
    end.

%% True once any response byte for the in-flight stream has been written:
%% `resp_framing' is set when the response header block goes out. A breach
%% between requests (no current stream) or before the response is answerable.
response_started(#state{current_stream = undefined}) ->
    false;
response_started(#state{current_stream = Id, streams = Streams}) ->
    case maps:find(Id, Streams) of
        {ok, #stream{resp_framing = undefined}} -> false;
        {ok, _}                                 -> true;
        error                                   -> false
    end.

%% Written raw rather than through send_response/4: at `line_too_long' or
%% `request_line_too_long' the parser failed before on_request/5 created a
%% stream, so there is nothing to send a response on.
send_error_response(Reason, State) ->
    Body = iolist_to_binary(h1_error:format(Reason)),
    Wire = [h1_message:status_line(h1_error:status(Reason), ?HTTP_1_1),
            h1_message:headers([{<<"content-length">>,
                                 integer_to_binary(byte_size(Body))},
                                {<<"connection">>, <<"close">>},
                                {<<"content-type">>, <<"text/plain">>}]),
            <<"\r\n">>, Body],
    _ = sock_send(State, Wire),
    State#state{close_after = true, current_stream = undefined}.

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
drive_parser({header, _KV, P}, State, Mode) ->
    %% The parser already accumulates every header in `partial_headers';
    %% it's read out once at headers_complete. Storing it again per header
    %% in the stream record (a record copy + map put each time) was pure
    %% duplication, so just keep draining the parser.
    drive_parser(h1_parse_erl:execute(P), State, Mode);
drive_parser({headers_complete, P}, State, Mode) ->
    State1 = State#state{parser = P},
    case on_headers_complete(State1, Mode) of
        {continue, State2} ->
            drive_parser(h1_parse_erl:execute(State2#state.parser), State2, Mode);
        {continue_buffer, Data, State2} ->
            %% The parser was reset after an interim (1xx) response;
            %% re-feed the bytes it had already buffered (the rest of a
            %% segment carrying several 1xx and/or the final response).
            drive_parser(h1_parse_erl:execute(State2#state.parser, Data),
                         State2, Mode);
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
    %% Keep the full origin-form request target (path plus any query) so the
    %% query string reaches the owner via the request/upgrade events.
    Id = State#state.next_stream_id,
    Stream = #stream{id = Id, state = open, method = Method,
                     path = URI, version = Version},
    State#state{parser = P,
                next_stream_id = Id + 1,
                current_stream = Id,
                streams = maps:put(Id, Stream, State#state.streams),
                recv_flow = State#state.flow_control,
                recv_unconsumed = 0,
                recv_paused = false}.

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
                streams = maps:put(Id, Stream, State#state.streams),
                recv_flow = Stream#stream.flow_control,
                recv_unconsumed = 0,
                recv_paused = false}.

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
    Headers = h1_parse_erl:get(State#state.parser, headers),
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
    Headers = h1_parse_erl:get(State#state.parser, headers),
    Stream1 = Stream0#stream{resp_headers = Headers},
    Status = Stream1#stream.status,
    case Status of
        100 ->
            %% Informational 100 Continue. Release any staged body.
            Stream2 = Stream1#stream{resp_headers = [], status = undefined},
            State1 = maybe_flush_pending_body(Id, put_stream(Stream2, State)),
            notify(State1#state.owner,
                   {informational, Id, Status, Headers}, self()),
            continue_after_informational(State1, Id);
        101 ->
            {upgrade_client, Stream1, State#state.parser, put_stream(Stream1, State)};
        _ when Status >= 100, Status =< 199 ->
            Stream2 = Stream1#stream{resp_headers = [], status = undefined},
            State1 = put_stream(Stream2, State),
            notify(State1#state.owner,
                   {informational, Id, Status, Headers}, self()),
            continue_after_informational(State1, Id);
        _ ->
            State1 = put_stream(Stream1, State),
            _ = emit_to_owner_or_handler_lookup(Id,
                {response, Id, Status, Headers}, State1),
            State2 = apply_peer_connection_policy(State1, Headers,
                        Stream1#stream.version),
            {continue, State2}
    end.

on_request_headers_complete(Stream1, Headers, State, Id) ->
    case detect_upgrade(State#state.parser, Headers) of
        {upgrade, Proto} ->
            Stream2 = Stream1#stream{state = half_closed_remote},
            State1 = put_stream(Stream2, State#state{upgrade_pending = true}),
            notify(State1#state.owner,
                   {upgrade, Id, Proto, Stream1#stream.method,
                    Stream1#stream.path, Headers}, self()),
            {pause, State1};
        no_upgrade ->
            Expect = h1_parse_erl:get(State#state.parser, expect),
            HasExpect = Expect =:= <<"100-continue">>,
            Stream2 = Stream1#stream{expect_continue = HasExpect},
            State1 = put_stream(Stream2, State),
            %% Resolve keep-alive/close policy before handing the request
            %% to the owner so the handler observes a consistent state.
            State2 = apply_request_close_policy(State1, Id, Headers,
                        Stream1#stream.version),
            notify(State2#state.owner,
                   {request, Id, Stream1#stream.method,
                    Stream1#stream.path, Headers}, self()),
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

%% Needle is always a lowercase literal at the call sites, so compare
%% against it directly instead of lowercasing it again on every lookup.
lookup_ci(Lower, Headers) ->
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
    Close = peer_asks_close(Headers, Version),
    State#state{keepalive = not Close,
                close_after = State#state.close_after orelse Close}.

%% Server: a request asking to close makes its own response the last one
%% (RFC 9112 §9.6). Responses to earlier pipelined requests keep the
%% connection open; requests after it are not processed.
apply_request_close_policy(State, Id, Headers, Version) ->
    case peer_asks_close(Headers, Version) of
        true when State#state.close_stream =:= undefined ->
            State#state{keepalive = false, close_stream = Id};
        true ->
            State#state{keepalive = false};
        false ->
            State
    end.

peer_asks_close(Headers, Version) ->
    case lookup_ci(<<"connection">>, Headers) of
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
    end.

deliver_data(Chunk, EndStream, #state{current_stream = Id} = State)
    when Id =/= undefined ->
    emit_to_owner_or_handler_lookup(Id, {data, Id, Chunk, EndStream},
                                    count_recv(Chunk, State));
deliver_data(_Chunk, _EndStream, State) ->
    State.

%% Body payload handed to the handler and not yet consumed. The parser yields
%% decoded payload, so chunked framing and trailers are never counted.
count_recv(Chunk, #state{recv_flow = manual, recv_unconsumed = U} = State) ->
    State#state{recv_unconsumed = U + byte_size(Chunk)};
count_recv(_Chunk, State) ->
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
emit_to_owner_or_handler(#stream{handler = Pid}, Event, State)
    when is_pid(Pid) ->
    %% A handler is set: deliver immediately. Events that arrive before a
    %% handler is registered go to the owner and, if buffered on the
    %% stream, are flushed by flush_handler/2 on registration.
    Pid ! {h1, self(), Event},
    State.

flush_handler(#stream{recv_buffer = []}, _Handler) -> [];
flush_handler(#stream{recv_buffer = Buf} = _Stream, Handler)
    when is_pid(Handler) ->
    Events = lists:reverse(Buf),
    lists:foreach(fun(E) -> Handler ! {h1, self(), E} end, Events),
    Events.

after_message_done(Rest, #state{mode = server, current_stream = Id} = State) ->
    State1 = finalize_request(Id, State),
    %% The body has ended: the window applies to the next request only.
    State2 = State1#state{parser = reset_parser(State1), current_stream = undefined,
                          recv_flow = auto, recv_unconsumed = 0,
                          recv_paused = false},
    if
        Id =:= State2#state.close_stream ->
            %% Last request on this connection: do not process anything
            %% after it (RFC 9112 §9.6).
            {ok, stop_reading(Rest =/= <<>>, State2)};
        byte_size(Rest) > 0 ->
            drive_parser(h1_parse_erl:execute(State2#state.parser, Rest), State2, server);
        true ->
            {ok, State2}
    end;
after_message_done(Rest, #state{mode = client, current_stream = Id} = State) ->
    State1 = finalize_response(Id, State),
    State2 = State1#state{parser = reset_parser(State1), current_stream = undefined,
                          recv_flow = auto, recv_unconsumed = 0,
                          recv_paused = false},
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
            Stream1 = maps:get(Id, State2#state.streams, Stream0),
            State3 = case Stream1#stream.state of
                S when S =:= half_closed_local; S =:= closed ->
                    %% Response already sent; both sides done — drop it.
                    State2#state{
                        streams = maps:remove(Id, State2#state.streams)};
                _ ->
                    put_stream(Stream1#stream{state = half_closed_remote,
                                              recv_ended = true}, State2)
            end,
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
    %% The response is done: its handler no longer holds a window.
    _ = case maps:find(Id, State1#state.streams) of
        {ok, Done} -> demonitor_handler(Done);
        error -> ok
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

%% Remove the first occurrence of Id, preserving order of the rest.
dequeue_id(Id, Q) ->
    queue:filter(fun(X) -> X =/= Id end, Q).

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

%% After an interim (1xx) response the parser is reset for the next
%% response on the same stream. Bytes it had already consumed into its
%% buffer (a following 1xx or the final response in the same segment)
%% must be re-fed to the fresh parser or they are silently dropped.
continue_after_informational(State, Id) ->
    Buffer = h1_parse_erl:get(State#state.parser, buffer),
    State1 = reset_parser_for_response(State, Id),
    case Buffer of
        <<>> -> {continue, State1};
        undefined -> {continue, State1};
        _ -> {continue_buffer, Buffer, State1}
    end.

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
            Flow = stream_flow(maps:get(flow_control, Opts,
                                        State#state.flow_control)),
            Stream = #stream{id = Id, state = open, method = Method,
                             path = Path, req_headers = Headers1,
                             pending_body = Pending, flow_control = Flow},
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

handle_send_response(From, StreamId, Status, Headers, State0)
  when Status >= 100, Status =< 199 ->
    %% A 1xx is interim, not the final response: same path and rules as
    %% send_informational/4 (RFC 9110 §15.2).
    handle_send_informational(From, StreamId, Status, Headers, State0);
handle_send_response(From, StreamId, Status, Headers, State0) ->
    %% Sending a normal response on an upgrade-pending connection means the
    %% handler declined the Upgrade. Drop the pending flag and resume
    %% reading the connection.
    {State, ResumeActions} = case State0#state.upgrade_pending of
        true  -> {rearm(State0#state{upgrade_pending = false}), []};
        false -> {State0, []}
    end,
    case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            %% If the request body is still incoming, the connection will
            %% close after this response — commit Connection: close now,
            %% before any send_data, so it is in the header block.
            State0b = maybe_set_early_close(StreamId, State),
            {Framing, HeadersWire, Close} =
                prepare_response(Stream, Status, Headers, no_body, State0b),
            Stream1 = Stream#stream{status = Status, resp_headers = Headers,
                                    resp_framing = Framing, state = open},
            Wire = [h1_message:status_line(Status, ?HTTP_1_1),
                    h1_message:headers(HeadersWire),
                    <<"\r\n">>],
            case sock_send(State0b, Wire) of
                ok ->
                    State1 = handler_close(Close, StreamId,
                                           put_stream(Stream1, State0b)),
                    {keep_state, State1, [{reply, From, ok} | ResumeActions]};
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

%% Send status line, headers, and body in a single socket write, then end
%% the stream. Coalesces what send_response/4 + send_data/4 would do as two
%% writes, framing the body with Content-Length.
handle_respond(From, StreamId, Status, Headers0, _Body, _Opts, State0)
  when Status >= 100, Status =< 199 ->
    %% Interim response: a 1xx carries no content (RFC 9112 §6.3), so the
    %% body is dropped and the stream waits for the final response.
    handle_send_informational(From, StreamId, Status, Headers0, State0);
handle_respond(From, StreamId, Status, Headers0, Body, Opts, State0) ->
    {State, ResumeActions} = case State0#state.upgrade_pending of
        true  -> {rearm(State0#state{upgrade_pending = false}), []};
        false -> {State0, []}
    end,
    case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            %% Resolve the drain budget up front so an invalid per-response
            %% `early_response_drain' is rejected before anything is sent.
            Budget = drain_budget_for(Opts, State#state.drain_budget),
            %% Committing a final response before the request body has been
            %% fully received: advertise Connection: close and linger-close
            %% (RFC 9112 §6.6) so the client reads the response before FIN.
            State0b = maybe_set_early_close(StreamId, State),
            {Framing, HeadersWire, Close} =
                prepare_response(Stream, Status, Headers0, Body, State0b),
            BodyWire = frame_body(Stream#stream{resp_framing = Framing}, Body, true),
            Wire = [h1_message:status_line(Status, ?HTTP_1_1),
                    h1_message:headers(HeadersWire),
                    <<"\r\n">>,
                    BodyWire],
            case sock_send(State0b, Wire) of
                ok ->
                    Stream1 = Stream#stream{status = Status, resp_headers = Headers0,
                                            resp_framing = Framing,
                                            state = half_closed_local},
                    State1 = handler_close(Close, StreamId,
                                           put_stream(Stream1, State0b)),
                    State2 = maybe_close_server_stream(StreamId, State1),
                    finish_server_send(From, StreamId, ResumeActions,
                                       Budget, State2);
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

%% A stream whose inbound side is not at end_stream when we commit a response
%% must close: set `close_after' so prepare_response/augment add
%% `Connection: close', and so the post-send logic enters the lingering close.
maybe_set_early_close(StreamId, #state{mode = server, streams = Streams} = State) ->
    case maps:find(StreamId, Streams) of
        {ok, #stream{recv_ended = false}} -> State#state{close_after = true};
        _ -> State
    end;
maybe_set_early_close(_StreamId, State) ->
    State.

%% Decide what to do once a server response (or final body chunk) is flushed.
%% maybe_close_server_stream/2 has already run:
%%   - stream removed         -> both sides done; close if `close_after', else
%%                               keep the connection alive for the next request.
%%   - stream present, closed -> early response; request body unfinished. Drain
%%                               and discard it (lingering close) so the client
%%                               receives the response before the socket closes.
%%   - stream present, open   -> mid-response streaming; keep going.
finish_server_send(From, StreamId, ResumeActions, State) ->
    finish_server_send(From, StreamId, ResumeActions,
                       State#state.drain_budget, State).

finish_server_send(From, StreamId, ResumeActions, Budget, State) ->
    Actions = [{reply, From, ok} | ResumeActions],
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{state = closed}} when State#state.mode =:= server ->
            enter_lingering_close(Actions, Budget, State);
        error when State#state.mode =:= server ->
            case closes_after(StreamId, State) of
                %% Input past the last request is waiting: stage the close
                %% so a reset cannot wipe out this response (RFC 9112 §9.6).
                true when State#state.unread ->
                    enter_lingering_close(Actions, Budget, State);
                true ->
                    {stop_and_reply, {shutdown, goaway_sent}, Actions, State};
                false ->
                    {keep_state, State, Actions}
            end;
        _ ->
            {keep_state, State, Actions}
    end.

%% The handler's own `Connection: close' makes this response the last.
handler_close(true, StreamId, State) -> mark_close_stream(StreamId, State);
handler_close(false, _StreamId, State) -> State.

%% True when the response on StreamId is the last on this connection.
closes_after(StreamId, #state{close_after = CloseAfter, close_stream = Last}) ->
    CloseAfter orelse StreamId =:= Last.

%% A response carrying `Connection: close' is the last one on this
%% connection (RFC 9112 §9.6). An earlier last stream stays the last.
mark_close_stream(Id, #state{close_stream = Last} = State)
  when is_integer(Last), Last =< Id ->
    State;
mark_close_stream(Id, #state{streams = Streams} = State) ->
    State1 = State#state{close_stream = Id},
    case maps:find(Id, Streams) of
        {ok, #stream{recv_ended = false}} ->
            %% Its request is still arriving; reading stops once it is done.
            State1;
        _ ->
            Later = lists:any(fun(K) -> K > Id end, maps:keys(Streams))
                    orelse parser_holds_input(State1),
            stop_reading(Later, State1)
    end.

parser_holds_input(#state{parser = P}) ->
    case h1_parse_erl:get(P, buffer) of
        B when is_binary(B), B =/= <<>> -> true;
        _ -> false
    end.

%% After the last request, input is read and discarded instead of parsed.
%% Reading goes on so the close knows whether input is waiting, within the
%% early-response drain byte budget.
stop_reading(Unread, State) ->
    State#state{reading = discard, unread = State#state.unread orelse Unread}.

discard_input(Data, #state{discarded = D} = State) ->
    D1 = D + byte_size(Data),
    State1 = State#state{unread = true, discarded = D1},
    case discard_limit(State1#state.drain_budget) of
        Max when Max =:= infinity; D1 < Max ->
            {keep_state, set_active_once(State1)};
        _ ->
            %% Over budget: stop reading and let the kernel push back.
            {keep_state, State1}
    end.

discard_limit({MaxBytes, _MaxMs}) -> MaxBytes;
discard_limit(disabled) -> 0.

%% Send FIN now that the full response is on the wire, then read and discard
%% the rest of the inbound body until the peer closes, the byte budget runs
%% out, or the linger timer fires. Inbound bytes are NOT fed to the parser
%% here, so an oversized leftover body cannot trip the body-size cap and RST
%% the connection. `disabled' skips the drain and closes right away (which may
%% reset mid-upload — the explicit opt-out).
enter_lingering_close(ReplyActions, disabled, State) ->
    _ = sock_shutdown_write(State),
    {stop_and_reply, {shutdown, early_close}, ReplyActions, State};
enter_lingering_close(ReplyActions, {MaxBytes, MaxMs}, State) ->
    _ = sock_shutdown_write(State),
    State1 = set_active_once(State#state{drain_left = MaxBytes}),
    Actions = ReplyActions
              ++ [{{timeout, idle}, infinity, idle},
                  {{timeout, request}, infinity, request},
                  {{timeout, linger}, MaxMs, linger}],
    {next_state, lingering_close, State1, Actions}.

%% Discard one inbound chunk during lingering close, debiting the byte budget.
%% When the budget is spent we stop (close) rather than keep reading; with an
%% `infinity' budget we only ever stop on the peer's FIN or the linger timer.
drain_discard(_Data, #state{drain_left = infinity} = State) ->
    {keep_state, set_active_once(State)};
drain_discard(Data, #state{drain_left = Left} = State) ->
    case Left - byte_size(Data) of
        Remaining when Remaining > 0 ->
            {keep_state, set_active_once(State#state{drain_left = Remaining})};
        _ ->
            {stop, {shutdown, drain_budget_exhausted}, State}
    end.

%% A response to HEAD and any 1xx, 204 or 304 ends at the blank line after
%% its header block, whatever its framing headers say (RFC 9112 §6.3 item 1,
%% RFC 9110 §6.4.1). Such a response gets `no_body' framing: nothing written
%% after the header block, so the next response on the connection starts
%% right there.
%%
%% Returns `{Framing, HeadersWire, Close}': `Close' is true when the
%% caller's own `Connection' header carries `close'. `Connection: close' is
%% added when this response is the last on the connection.
prepare_response(#stream{id = Id, method = Method}, Status, Headers, Body, State) ->
    CloseAfter = closes_after(Id, State),
    case bodyless(Method, Status) of
        true  -> prepare_bodyless(Method, Status, Headers, Body, CloseAfter);
        false -> prepare_response(Headers, Body, CloseAfter)
    end.

bodyless(<<"HEAD">>, _Status) -> true;
bodyless(_Method, Status) when Status >= 100, Status =< 199 -> true;
bodyless(_Method, 204) -> true;
bodyless(_Method, 304) -> true;
bodyless(_Method, _Status) -> false.

%% No Transfer-Encoding on any of them (RFC 9112 §6.1 forbids it on 1xx and
%% 204, and there is no body to encode). No Content-Length on 1xx and 204
%% (RFC 9110 §8.6). On 304 and HEAD a caller-set Content-Length is kept as
%% metadata. A HEAD answered through respond/5 with the GET body gets the
%% Content-Length a GET would get (RFC 9110 §9.3.2); an empty body says
%% nothing about that length, and a 304's body is not the representation, so
%% neither gets one.
prepare_bodyless(Method, Status, Headers, Body, CloseAfter) ->
    {CL, _TE, HasConn, Close} = scan_response_headers(Headers),
    Headers1 = strip_framing(Status, Headers),
    Headers2 = case {Method, Status, CL, Body} of
        {<<"HEAD">>, S, undefined, B} when S =/= 204, S =/= 304, B =/= no_body ->
            case iolist_size(B) of
                0 -> Headers1;
                N -> Headers1 ++ [{<<"content-length">>, integer_to_binary(N)}]
            end;
        _ ->
            Headers1
    end,
    {no_body, ensure_close(Headers2, HasConn, CloseAfter), Close}.

strip_framing(Status, Headers) ->
    DropCL = Status =:= 204 orelse (Status >= 100 andalso Status =< 199),
    [H || {N, _} = H <- Headers, keep_framing_header(h1_parse_erl:to_lower(N), DropCL)].

keep_framing_header(<<"transfer-encoding">>, _DropCL) -> false;
keep_framing_header(<<"content-length">>, DropCL) -> not DropCL;
keep_framing_header(_Name, _DropCL) -> true.

%% Decide framing and build the response header block in a single pass over
%% the caller's headers, instead of rescanning (and re-lowercasing every
%% name) once per decision. `Body' is `no_body' for a header-only send, or
%% the body iodata for a coalesced respond (used to add Content-Length when
%% the caller set no framing header).
prepare_response(Headers, Body, CloseAfter) ->
    {CL0, TE, HasConn, Close} = scan_response_headers(Headers),
    {Headers1, CL} = case {CL0, TE, Body} of
        {undefined, undefined, B} when B =/= no_body ->
            CLBin = integer_to_binary(iolist_size(B)),
            {Headers ++ [{<<"content-length">>, CLBin}], CLBin};
        _ ->
            {Headers, CL0}
    end,
    Framing = case CL of
        undefined -> chunked;
        _ ->
            case h1_parse_erl:to_int(iolist_to_binary(CL)) of
                {ok, N} -> {content_length, N};
                false   -> {content_length, 0}
            end
    end,
    {Framing, augment(Framing, TE, HasConn, CloseAfter, Headers1), Close}.

%% First occurrence of each framing-relevant header (case-insensitive,
%% matching lookup_ci/2), collected in one traversal, plus whether any
%% `Connection' header carries the `close' token.
scan_response_headers(Headers) ->
    scan_response_headers(Headers, undefined, undefined, false, false).

scan_response_headers([], CL, TE, HasConn, Close) ->
    {CL, TE, HasConn, Close};
scan_response_headers([{N, V} | Rest], CL, TE, HasConn, Close) ->
    case h1_parse_erl:to_lower(N) of
        <<"content-length">> ->
            scan_response_headers(Rest, first(CL, V), TE, HasConn, Close);
        <<"transfer-encoding">> ->
            scan_response_headers(Rest, CL, first(TE, V), HasConn, Close);
        <<"connection">> ->
            Close1 = Close orelse
                has_token(h1_parse_erl:to_lower(iolist_to_binary(V)), <<"close">>),
            scan_response_headers(Rest, CL, TE, true, Close1);
        _ ->
            scan_response_headers(Rest, CL, TE, HasConn, Close)
    end.

first(undefined, V) -> V;
first(Existing, _)  -> Existing.

%% Add Transfer-Encoding: chunked / Connection: close as needed, reusing the
%% header presence already discovered by scan_response_headers/1.
augment(chunked, undefined, HasConn, CloseAfter, Headers) ->
    ensure_close(Headers ++ [{<<"transfer-encoding">>, <<"chunked">>}],
                 HasConn, CloseAfter);
augment(chunked, TE, HasConn, CloseAfter, Headers) ->
    H1 = case has_token(h1_parse_erl:to_lower(iolist_to_binary(TE)), <<"chunked">>) of
        true  -> Headers;
        %% We frame the body as chunked, so the advertised Transfer-Encoding
        %% must end with `chunked' (RFC 9112 §6.1) or the peer mis-frames it.
        false -> append_chunked_te(Headers)
    end,
    ensure_close(H1, HasConn, CloseAfter);
augment(_Framing, _TE, HasConn, CloseAfter, Headers) ->
    ensure_close(Headers, HasConn, CloseAfter).

append_chunked_te(Headers) ->
    [case h1_parse_erl:to_lower(N) of
         <<"transfer-encoding">> -> {N, [V, <<", chunked">>]};
         _ -> {N, V}
     end || {N, V} <- Headers].

ensure_close(Headers, false, true) ->
    Headers ++ [{<<"connection">>, <<"close">>}];
ensure_close(Headers, _HasConn, _CloseAfter) ->
    Headers.

handle_send_data(From, StreamId, Data, EndStream, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, Stream} ->
            case send_body(State, Stream, Data, EndStream) of
                ok ->
                    Stream1 = case EndStream of
                        true -> Stream#stream{state = half_closed_local};
                        false -> Stream
                    end,
                    State1 = put_stream(Stream1, State),
                    State2 = maybe_close_server_stream(StreamId, State1),
                    finish_server_send(From, StreamId, [], State2);
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

%% Body data offered for a bodyless response (HEAD, 204, 304) is dropped:
%% nothing may follow its header block (RFC 9112 §6.3).
send_body(_State, #stream{resp_framing = no_body}, _Data, _EndStream) ->
    ok;
send_body(State, Stream, Data, EndStream) ->
    sock_send(State, frame_body(Stream, Data, EndStream)).

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
        {ok, #stream{state = half_closed_local, recv_ended = true}} ->
            %% Both directions done — drop the stream so the map does not
            %% grow one zombie entry per keep-alive request.
            State#state{streams = maps:remove(StreamId, State#state.streams)};
        {ok, #stream{state = half_closed_local} = S} ->
            %% Response finished before the request body was fully read.
            %% Keep the stream; finalize_request removes it once draining
            %% completes.
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
                    end_server_stream(From, StreamId, Stream, State);
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        {ok, #stream{resp_framing = no_body} = Stream} ->
            %% A bodyless response has no trailer section (RFC 9112 §6.3):
            %% drop the trailers and end the stream.
            end_server_stream(From, StreamId, Stream, State);
        {ok, _} ->
            {keep_state_and_data,
             [{reply, From, {error, trailers_require_chunked}}]};
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

%% The trailer section ends the response: finish the stream as a final
%% send_data/4 does, so it is dropped once both sides are done and a pending
%% close or early-response drain runs.
end_server_stream(From, StreamId, Stream, State) ->
    State1 = put_stream(Stream#stream{state = half_closed_local}, State),
    State2 = maybe_close_server_stream(StreamId, State1),
    finish_server_send(From, StreamId, [], State2).

%% Interim (1xx) response ahead of the final one. 101 is carved out for
%% the Upgrade machinery, and HTTP/1.0 clients must not see 1xx at all
%% (RFC 9110 §15.2). Writing is only legal while the final response
%% headers have not been committed (`#stream.status' is set by
%% send_response/respond).
handle_send_informational(From, _StreamId, Status, _Headers, _State)
  when Status < 100; Status > 199; Status =:= 101 ->
    {keep_state_and_data, [{reply, From, {error, invalid_informational_status}}]};
handle_send_informational(From, StreamId, Status, Headers, State) ->
    case maps:find(StreamId, State#state.streams) of
        {ok, #stream{version = ?HTTP_1_0}} ->
            {keep_state_and_data, [{reply, From, {error, http_1_0}}]};
        {ok, #stream{status = undefined} = Stream} ->
            %% A 1xx ends at its header block: no Content-Length or
            %% Transfer-Encoding (RFC 9110 §8.6, RFC 9112 §6.1).
            Wire = [h1_message:status_line(Status, ?HTTP_1_1),
                    h1_message:headers(strip_framing(Status, Headers)),
                    <<"\r\n">>],
            case sock_send(State, Wire) of
                ok ->
                    Stream1 = case Status of
                        100 -> Stream#stream{continue_sent = true};
                        _ -> Stream
                    end,
                    {keep_state, put_stream(Stream1, State),
                     [{reply, From, ok}]};
                {error, R} ->
                    {keep_state_and_data, [{reply, From, {error, R}}]}
            end;
        {ok, _} ->
            {keep_state_and_data,
             [{reply, From, {error, response_already_started}}]};
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
    %% `upgrade_wire/1' strips the `:path' pseudo-header into the
    %% request-line before encoding the rest of the headers with
    %% `h1_message:headers/1', which rejects pseudo-headers. Do NOT
    %% encode `Hs1' directly here.
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
                    %% h1 owns the framing headers: drop any caller-supplied
                    %% connection/upgrade so the 101 carries exactly one of
                    %% each (duplicates break spec-strict WebSocket clients).
                    Extra = [H || {N, _} = H <- ExtraHeaders,
                                  not lists:member(
                                        h1_parse_erl:to_lower(N),
                                        [<<"connection">>, <<"upgrade">>])],
                    Hdrs = [{<<"connection">>, <<"Upgrade">>},
                            {<<"upgrade">>, Proto}
                            | Extra],
                    Wire = [h1_message:status_line(101, ?HTTP_1_1),
                            h1_message:headers(Hdrs),
                            <<"\r\n">>],
                    case send_handover_response(Wire, State) of
                        ok ->
                            Buffer = hand_over_socket(From, State),
                            gen_statem:reply(From, {ok, State#state.socket, Buffer}),
                            notify(State#state.owner,
                                {upgraded, StreamId, Proto,
                                 State#state.socket, Buffer, Hdrs}, self()),
                            {stop, {shutdown, upgraded},
                             State#state{socket_handed_off = true}};
                        {error, R} ->
                            handover_failed(From, R, State)
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
            case send_handover_response(Wire, State) of
                ok ->
                    Buffer = hand_over_socket(From, State),
                    Transport = State#state.transport,
                    Socket = State#state.socket,
                    gen_statem:reply(From,
                                     {ok, Transport, Socket, Buffer}),
                    notify(State#state.owner,
                           {connected, StreamId, Transport, Socket, Buffer},
                           self()),
                    {stop, {shutdown, connected},
                     State#state{socket_handed_off = true}};
                {error, R} ->
                    handover_failed(From, R, State)
            end;
        error ->
            {keep_state_and_data, [{reply, From, {error, unknown_stream}}]}
    end.

%% Write the response that ends HTTP on this connection. The socket goes passive
%% first, so whatever a client sends once it reads the response stays in the
%% socket for the new owner. A socket that cannot go passive is already closed.
send_handover_response(Wire, State) ->
    case set_passive(State) of
        ok -> sock_send(State, Wire);
        {error, _} -> {error, closed}
    end.

%% The socket is passive, so nothing more can reach this mailbox: `setopts'
%% returning means gen_tcp's port or the TLS process has stopped delivering, and
%% it sent anything earlier before its reply. Bytes delivered before that go to
%% the caller in the buffer. Close and error events go to its mailbox, because
%% `gen_tcp:controlling_process/2' only forwards what is still queued here and
%% `ssl:controlling_process/2' forwards nothing.
hand_over_socket({NewOwner, _}, #state{parser = Parser, transport = Transport,
                                       socket = Socket}) ->
    Parsed = h1_parse_erl:get(Parser, buffer),
    {Delivered, Events} = drain_socket_messages(Socket, [], []),
    Visible = case {give_socket(Transport, Socket, NewOwner), Events} of
        %% The socket went away without an event, and an active owner still has
        %% to learn it.
        {{error, _}, []} -> [closed_event(Transport, Socket)];
        _ -> Events
    end,
    lists:foreach(fun(Event) -> NewOwner ! Event end, Visible),
    iolist_to_binary([Parsed | Delivered]).

drain_socket_messages(S, Data, Events) ->
    receive
        {tcp, S, Bin} -> drain_socket_messages(S, [Bin | Data], Events);
        {ssl, S, Bin} -> drain_socket_messages(S, [Bin | Data], Events);
        {tcp_closed, S} = E -> drain_socket_messages(S, Data, [E | Events]);
        {ssl_closed, S} = E -> drain_socket_messages(S, Data, [E | Events]);
        {tcp_error, S, _} = E -> drain_socket_messages(S, Data, [E | Events]);
        {ssl_error, S, _} = E -> drain_socket_messages(S, Data, [E | Events])
    after 0 ->
        {lists:reverse(Data), lists:reverse(Events)}
    end.

give_socket(gen_tcp, Socket, NewOwner) -> gen_tcp:controlling_process(Socket, NewOwner);
give_socket(ssl, Socket, NewOwner)     -> ssl:controlling_process(Socket, NewOwner).

closed_event(gen_tcp, Socket) -> {tcp_closed, Socket};
closed_event(ssl, Socket)     -> {ssl_closed, Socket}.

%% The socket is passive and no handover happened. Read again, or a peer that
%% leaves goes unnoticed. The write failed, so no tunnel is coming: a pending
%% upgrade is over too, and any bytes still queued go through the parser.
handover_failed(From, Reason, State) ->
    State1 = rearm(State#state{upgrade_pending = false}),
    {keep_state, State1, [{reply, From, {error, Reason}}]}.

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
