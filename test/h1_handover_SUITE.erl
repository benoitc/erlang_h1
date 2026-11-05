%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc Bytes and close events must survive the socket handover done by
%%% `h1:accept_connect/3,4' and `h1:accept_upgrade/3'.
%%%
%%% The new owner reads only the returned buffer and the passive socket. A
%%% byte that lands in its mailbox counts as a failure, because an owner
%%% using `recv' would never see it.
%%%
%%% The `load_*' cases race a real client against the handover. The `queued_*'
%%% cases suspend the connection so the mailbox holds a known message when the
%%% accept call runs, which makes the outcome independent of timing.
-module(h1_handover_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, suite/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).

-export([load_connect/1,
         load_upgrade/1,
         load_upgrade_no_connection_token/1,
         queued_data_connect/1,
         queued_data_upgrade_no_connection_token/1,
         queued_close_connect/1,
         queued_error_connect/1,
         peer_closed_before_accept/1,
         bytes_then_close_after_response/1,
         socket_is_passive_after_handover/1,
         failed_send_connect/1,
         failed_send_upgrade/1]).

-define(WORKERS, 50).
-define(ROUNDS, 20).
-define(RECV_MS, 2000).
-define(WAIT_MS, 5000).
-define(PAYLOAD, <<"first-bytes-after-the-response:0123456789">>).

suite() -> [{timetrap, {minutes, 5}}].

all() -> [{group, tcp}, {group, ssl}].

groups() ->
    Cases = [load_connect,
             load_upgrade,
             load_upgrade_no_connection_token,
             queued_data_connect,
             queued_data_upgrade_no_connection_token,
             queued_close_connect,
             queued_error_connect,
             peer_closed_before_accept,
             bytes_then_close_after_response,
             socket_is_passive_after_handover,
             failed_send_connect,
             failed_send_upgrade],
    [{tcp, [], Cases}, {ssl, [], Cases}].

init_per_suite(Config) ->
    case os:find_executable("openssl") of
        false ->
            {skip, openssl_not_found};
        _ ->
            {ok, _} = application:ensure_all_started(h1),
            {ok, _} = application:ensure_all_started(ssl),
            Config
    end.

end_per_suite(_Config) ->
    application:stop(h1),
    ok.

init_per_group(Transport, Config) ->
    [{transport, Transport} | Config].

end_per_group(_Transport, _Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    process_flag(trap_exit, true),
    Config.

end_per_testcase(_TC, Config) ->
    case ?config(server_ref, Config) of
        undefined -> ok;
        Ref -> try h1:stop_server(Ref) catch _:_ -> ok end
    end,
    ok.

%% ----------------------------------------------------------------------------
%% Races under load
%% ----------------------------------------------------------------------------

load_connect(Config) ->
    load(connect_request(), fun accept_connect/2, Config).

load_upgrade(Config) ->
    load(upgrade_request(), fun accept_upgrade/2, Config).

%% Without the `Connection: upgrade' token the request is reported as an
%% ordinary one, so the socket is re-armed before the handler accepts it.
load_upgrade_no_connection_token(Config) ->
    load(upgrade_request_no_token(), fun accept_upgrade/2, Config).

load(Request, Accept, Config0) ->
    Collector = self(),
    Handler = fun(Conn, Id, _M, _P, _Hs) ->
        Collector ! {outcome, read_payload(Accept(Conn, Id), ?PAYLOAD)}
    end,
    Config = start_server(Handler, #{acceptors => ?WORKERS}, Config0),
    Transport = sock_mod(Config),
    Port = h1:server_port(?config(server_ref, Config)),
    Workers = [spawn_link(fun() ->
                   [client_round(Transport, Port, Request)
                    || _ <- lists:seq(1, ?ROUNDS)]
               end) || _ <- lists:seq(1, ?WORKERS)],
    Outcomes = collect(?WORKERS * ?ROUNDS, []),
    lists:foreach(fun(W) ->
                      receive {'EXIT', W, normal} -> ok
                      after ?WAIT_MS -> ct:fail({worker_stuck, W})
                      end
                  end, Workers),
    Failed = [O || O <- Outcomes, O =/= ok],
    ct:pal("~p rounds, ~p failed, by kind: ~p",
           [length(Outcomes), length(Failed), tally(Failed)]),
    ?assertEqual([], Failed).

client_round(Transport, Port, Request) ->
    Sock = client_connect(Transport, Port),
    ok = Transport:send(Sock, Request),
    <<_/binary>> = recv_response_head(Transport, Sock),
    %% Three writes, so a loss in the middle shows up as well as one at the
    %% start and the order is checked across segments.
    Size = byte_size(?PAYLOAD) div 3,
    <<A:Size/binary, B:Size/binary, C/binary>> = ?PAYLOAD,
    ok = Transport:send(Sock, A),
    ok = Transport:send(Sock, B),
    ok = Transport:send(Sock, C),
    %% Keep the connection up until the server had its chance to read.
    _ = Transport:recv(Sock, 0, ?RECV_MS),
    Transport:close(Sock).

collect(0, Acc) -> Acc;
collect(N, Acc) ->
    receive {outcome, O} -> collect(N - 1, [O | Acc])
    after 60000 -> ct:fail({missing_outcomes, N, tally(Acc)})
    end.

tally(Outcomes) ->
    Kind = fun({Tag, _, _}) -> Tag; ({Tag, _}) -> Tag; (Tag) -> Tag end,
    maps:to_list(lists:foldl(fun(O, M) ->
                                 maps:update_with(Kind(O), fun(V) -> V + 1 end,
                                                  1, M)
                             end, #{}, Outcomes)).

%% ----------------------------------------------------------------------------
%% Known mailbox contents
%% ----------------------------------------------------------------------------

queued_data_connect(Config) ->
    queued_data(connect_request(), fun accept_connect/2, Config).

queued_data_upgrade_no_connection_token(Config) ->
    queued_data(upgrade_request_no_token(), fun accept_upgrade/2, Config).

queued_data(Request, Accept, Config0) ->
    Test = self(),
    Handler = fun(Conn, Id, _M, _P, _Hs) ->
        Test ! {accepting, Conn, self()},
        receive accept -> ok end,
        Test ! {outcome, read_payload(Accept(Conn, Id), ?PAYLOAD)}
    end,
    Config = start_server(Handler, #{}, Config0),
    Transport = sock_mod(Config),
    Client = client_connect(Transport, h1:server_port(?config(server_ref, Config))),
    ok = Transport:send(Client, Request),
    Conn = await_call_queued(),
    ok = Transport:send(Client, ?PAYLOAD),
    await_queued(Conn, fun({T, _, Data}) when T =:= tcp; T =:= ssl ->
                               is_binary(Data);
                          (_) -> false
                       end),
    ok = sys:resume(Conn),
    receive {outcome, O} -> ?assertEqual(ok, O)
    after ?WAIT_MS -> ct:fail(no_outcome)
    end,
    Transport:close(Client).

%% Injected rather than caused by the peer: a real close kills the port or the
%% TLS process, which makes the write fail and no handover happens (see
%% `peer_closed_before_accept'). Here the write succeeds and the drain is the
%% only thing that can see the event.
queued_close_connect(Config) ->
    Closed = case ?config(transport, Config) of
                 tcp -> tcp_closed;
                 ssl -> ssl_closed
             end,
    queued_event(fun(Sock) -> {Closed, Sock} end, Config).

queued_error_connect(Config) ->
    Error = case ?config(transport, Config) of
                tcp -> tcp_error;
                ssl -> ssl_error
            end,
    queued_event(fun(Sock) -> {Error, Sock, injected} end, Config).

queued_event(MakeEvent, Config0) ->
    Test = self(),
    Handler = fun(Conn, Id, _M, _P, _Hs) ->
        Test ! {accepting, Conn, self()},
        receive accept -> ok end,
        {ok, _T, Sock, Buf} = h1:accept_connect(Conn, Id, []),
        Event = MakeEvent(Sock),
        Test ! {owner_saw, Buf,
                receive Event -> event after ?WAIT_MS -> no_event end}
    end,
    Config = start_server(Handler, #{}, Config0),
    Transport = sock_mod(Config),
    Client = client_connect(Transport, h1:server_port(?config(server_ref, Config))),
    ok = Transport:send(Client, connect_request()),
    Conn = await_call_queued(),
    Conn ! MakeEvent(conn_socket(Conn)),
    ok = sys:resume(Conn),
    receive {owner_saw, Buf, Seen} ->
        ?assertEqual(<<>>, Buf),
        ?assertEqual(event, Seen)
    after 2 * ?WAIT_MS -> ct:fail(no_owner_result)
    end,
    Transport:close(Client).

%% The peer is gone before the accept: nothing was promised to it, so the
%% caller gets an error and the connection stops by itself.
peer_closed_before_accept(Config0) ->
    Test = self(),
    Handler = fun(Conn, Id, _M, _P, _Hs) ->
        Test ! {accepting, Conn, self()},
        receive accept -> ok end,
        Test ! {result, h1:accept_connect(Conn, Id, [])}
    end,
    Config = start_server(Handler, #{}, Config0),
    Transport = sock_mod(Config),
    Client = client_connect(Transport, h1:server_port(?config(server_ref, Config))),
    ok = Transport:send(Client, connect_request()),
    Conn = await_call_queued(),
    MRef = erlang:monitor(process, Conn),
    ok = Transport:close(Client),
    await_queued(Conn, fun({T, _}) -> T =:= tcp_closed orelse T =:= ssl_closed;
                          (_) -> false
                       end),
    ok = sys:resume(Conn),
    receive {result, R} -> ?assertEqual({error, closed}, R)
    after ?WAIT_MS -> ct:fail(no_result)
    end,
    receive {'DOWN', MRef, process, Conn, _} -> ok
    after ?WAIT_MS -> ct:fail(connection_still_running)
    end.

%% A client that writes and closes right after the response: the new owner
%% gets every byte first, and then the close.
bytes_then_close_after_response(Config0) ->
    Test = self(),
    Handler = fun(Conn, Id, _M, _P, _Hs) ->
        {ok, T, Sock, Buf} = h1:accept_connect(Conn, Id, []),
        Test ! {outcome, read_to_close(T, Sock, Buf)}
    end,
    Config = start_server(Handler, #{}, Config0),
    Transport = sock_mod(Config),
    Port = h1:server_port(?config(server_ref, Config)),
    Client = client_connect(Transport, Port),
    ok = Transport:send(Client, connect_request()),
    _ = recv_response_head(Transport, Client),
    ok = Transport:send(Client, ?PAYLOAD),
    ok = Transport:close(Client),
    receive {outcome, O} -> ?assertEqual({ok, ?PAYLOAD}, O)
    after ?WAIT_MS -> ct:fail(no_outcome)
    end.

socket_is_passive_after_handover(Config0) ->
    Test = self(),
    Handler = fun(Conn, Id, _M, _P, _Hs) ->
        {ok, T, Sock, _Buf} = h1:accept_connect(Conn, Id, []),
        Test ! {active, opts_mod(T):getopts(Sock, [active])}
    end,
    Config = start_server(Handler, #{}, Config0),
    Transport = sock_mod(Config),
    Client = client_connect(Transport, h1:server_port(?config(server_ref, Config))),
    ok = Transport:send(Client, connect_request()),
    receive {active, Opts} -> ?assertEqual({ok, [{active, false}]}, Opts)
    after ?WAIT_MS -> ct:fail(no_opts)
    end,
    Transport:close(Client).

%% ----------------------------------------------------------------------------
%% A failed write
%% ----------------------------------------------------------------------------

failed_send_connect(Config) ->
    failed_send(connect_request(), fun h1:accept_connect/3, Config).

failed_send_upgrade(Config) ->
    failed_send(upgrade_request(), fun h1:accept_upgrade/3, Config).

%% The write side is shut before the accept, so the socket still takes option
%% changes but the response cannot be written. The caller gets the error, and
%% the connection must still be reading: it has to notice the peer leaving
%% instead of sitting on a passive socket until a timer fires. A connection
%% that stops as soon as the write fails is fine too.
failed_send(Request, Accept, Config0) ->
    Test = self(),
    Handler = fun(Conn, Id, _M, _P, _Hs) ->
        Test ! {accepting, Conn, self()},
        receive accept -> ok end,
        Test ! {result, Accept(Conn, Id, [])},
        receive stop -> ok end
    end,
    Config = start_server(Handler, #{idle_timeout => infinity}, Config0),
    Transport = sock_mod(Config),
    Client = client_connect(Transport, h1:server_port(?config(server_ref, Config))),
    ok = Transport:send(Client, Request),
    Conn = await_call_queued(),
    MRef = erlang:monitor(process, Conn),
    ok = shutdown_write(conn_socket(Conn), Config),
    ok = sys:resume(Conn),
    receive {result, R} -> ?assertMatch({error, _}, R)
    after ?WAIT_MS -> ct:fail(no_result)
    end,
    _ = Transport:close(Client),
    receive {'DOWN', MRef, process, Conn, _} -> ok
    after ?WAIT_MS -> ct:fail(connection_stuck_on_passive_socket)
    end.

shutdown_write(Sock, Config) ->
    (sock_mod(Config)):shutdown(Sock, write).

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

accept_connect(Conn, Id) ->
    case h1:accept_connect(Conn, Id, []) of
        {ok, T, Sock, Buf} -> {ok, T, Sock, Buf};
        Other -> Other
    end.

accept_upgrade(Conn, Id) ->
    case h1:accept_upgrade(Conn, Id, []) of
        {ok, Sock, Buf} -> {ok, socket_transport(Sock), Sock, Buf};
        Other -> Other
    end.

socket_transport(Sock) when is_port(Sock) -> gen_tcp;
socket_transport(_) -> ssl.

%% Read through the buffer and the socket only, as an owner using `recv' does.
read_payload({ok, T, Sock, Buf}, Want) ->
    case read_exact(T, Sock, Buf, byte_size(Want)) of
        {ok, Want} ->
            _ = T:send(Sock, <<"k">>),
            ok;
        {ok, Other} ->
            {corrupt, Other};
        {error, Reason, Got} ->
            %% Tell a byte parked in the mailbox apart from a lost one.
            case socket_messages(Sock) of
                [] -> {lost, Reason, Got};
                Msgs -> {in_mailbox, Got, Msgs}
            end
    end;
read_payload(Other, _Want) ->
    {accept_failed, Other}.

read_exact(_T, _Sock, Buf, Size) when byte_size(Buf) >= Size ->
    {ok, Buf};
read_exact(T, Sock, Buf, Size) ->
    case T:recv(Sock, 0, ?RECV_MS) of
        {ok, More} -> read_exact(T, Sock, <<Buf/binary, More/binary>>, Size);
        {error, Reason} -> {error, Reason, Buf}
    end.

read_to_close(T, Sock, Buf) ->
    case T:recv(Sock, 0, ?RECV_MS) of
        {ok, More} -> read_to_close(T, Sock, <<Buf/binary, More/binary>>);
        {error, closed} -> {ok, Buf};
        {error, Reason} -> {error, Reason, Buf}
    end.

socket_messages(Sock) ->
    receive
        {T, Sock, _} = M when T =:= tcp; T =:= ssl; T =:= tcp_error; T =:= ssl_error ->
            [M | socket_messages(Sock)];
        {T, Sock} = M when T =:= tcp_closed; T =:= ssl_closed ->
            [M | socket_messages(Sock)]
    after 0 -> []
    end.

%% Suspend the connection, tell the handler to accept, and return once the
%% accept call sits unprocessed in the connection's mailbox.
await_call_queued() ->
    receive
        {accepting, Conn, Owner} ->
            ok = sys:suspend(Conn),
            Owner ! accept,
            await_queued(Conn, fun({'$gen_call', _, {A, _, _}}) ->
                                       A =:= accept_connect orelse
                                           A =:= accept_upgrade;
                                  (_) -> false
                               end),
            Conn
    after ?WAIT_MS -> ct:fail(no_request)
    end.

await_queued(Pid, Pred) ->
    await_queued(Pid, Pred, 500).

await_queued(_Pid, _Pred, 0) ->
    ct:fail(message_never_queued);
await_queued(Pid, Pred, N) ->
    {messages, Msgs} = process_info(Pid, messages),
    case lists:any(Pred, Msgs) of
        true -> ok;
        false ->
            timer:sleep(10),
            await_queued(Pid, Pred, N - 1)
    end.

%% The socket is not part of the public API before the handover.
conn_socket(Conn) ->
    {_StateName, State} = sys:get_state(Conn),
    {value, Sock} = lists:search(
                      fun(E) -> is_port(E) orelse
                                    (is_tuple(E) andalso tuple_size(E) > 0
                                     andalso element(1, E) =:= sslsocket)
                      end, tuple_to_list(State)),
    Sock.

connect_request() ->
    <<"CONNECT host:443 HTTP/1.1\r\nHost: host:443\r\n\r\n">>.

upgrade_request() ->
    <<"GET / HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\n"
      "Upgrade: test-proto\r\n\r\n">>.

upgrade_request_no_token() ->
    <<"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: test-proto\r\n\r\n">>.

recv_response_head(Transport, Sock) ->
    recv_response_head(Transport, Sock, <<>>).

recv_response_head(Transport, Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            {ok, More} = Transport:recv(Sock, 0, ?WAIT_MS),
            recv_response_head(Transport, Sock, <<Acc/binary, More/binary>>);
        _ ->
            Acc
    end.

client_connect(gen_tcp, Port) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port,
                              [binary, {active, false}, {packet, raw},
                               {nodelay, true}], ?WAIT_MS),
    S;
client_connect(ssl, Port) ->
    {ok, S} = ssl:connect("localhost", Port,
                          [binary, {active, false}, {packet, raw},
                           {nodelay, true}, {verify, verify_none},
                           {alpn_advertised_protocols, [<<"http/1.1">>]}],
                          ?WAIT_MS),
    S.

sock_mod(Config) ->
    case ?config(transport, Config) of
        tcp -> gen_tcp;
        ssl -> ssl
    end.

opts_mod(gen_tcp) -> inet;
opts_mod(ssl) -> ssl.

start_server(Handler, Extra, Config) ->
    Base = #{handler => Handler},
    Opts = case ?config(transport, Config) of
               tcp ->
                   Base#{transport => tcp};
               ssl ->
                   {Cert, Key} = make_cert(?config(priv_dir, Config)),
                   Base#{transport => ssl, cert => Cert, key => Key}
           end,
    {ok, Ref} = h1:start_server(0, maps:merge(Opts, Extra)),
    [{server_ref, Ref} | Config].

make_cert(PrivDir) ->
    CertFile = filename:join(PrivDir, "cert.pem"),
    KeyFile = filename:join(PrivDir, "key.pem"),
    case filelib:is_regular(CertFile) andalso filelib:is_regular(KeyFile) of
        true ->
            {CertFile, KeyFile};
        false ->
            Cmd = io_lib:format(
                    "openssl req -x509 -newkey rsa:2048 -keyout ~s -out ~s "
                    "-days 1 -nodes -subj '/CN=localhost' 2>/dev/null",
                    [KeyFile, CertFile]),
            _ = os:cmd(lists:flatten(Cmd)),
            {CertFile, KeyFile}
    end.
