%%% @doc Loopback end-to-end tests for h1_connection gen_statem.
%%%
%%% We wire two h1_connection processes (client mode + server mode)
%%% together over a localhost gen_tcp socket pair and drive real
%%% request/response flows through them.
-module(h1_connection_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    simple_get/1,
    post_content_length/1,
    post_chunked/1,
    response_chunked/1,
    response_with_trailers/1,
    keep_alive_two_requests/1,
    pipelined_two_requests/1,
    expect_100_continue/1,
    server_connection_close/1,
    client_closes_on_connection_close/1,
    upgrade_server_side/1,
    upgrade_client_side/1,
    upgrade_capsule_exchange/1,
    idle_timeout_closes_silent_connection/1,
    pipeline_disabled_returns_error/1,
    client_auto_adds_host_header/1,
    server_rejects_1_1_request_without_host_with_400/1,
    close_delimited_response_terminates_on_eof/1
]).

all() ->
    [{group, basic},
     {group, keepalive},
     {group, expect},
     {group, upgrade},
     {group, hardening}].

groups() ->
    [{basic, [],
      [simple_get, post_content_length, post_chunked, response_chunked,
       response_with_trailers]},
     {keepalive, [],
      [keep_alive_two_requests, pipelined_two_requests,
       server_connection_close, client_closes_on_connection_close]},
     {expect, [],
      [expect_100_continue]},
     {upgrade, [],
      [upgrade_server_side, upgrade_client_side, upgrade_capsule_exchange]},
     {hardening, [],
      [idle_timeout_closes_silent_connection,
       pipeline_disabled_returns_error,
       client_auto_adds_host_header,
       server_rejects_1_1_request_without_host_with_400,
       close_delimited_response_terminates_on_eof]}].

init_per_suite(Config) -> Config.
end_per_suite(_Config) -> ok.

init_per_testcase(_TC, Config) ->
    %% gen_statem:start_link links the test process to the connection;
    %% when either side shuts down with {shutdown, _} the signal would
    %% kill the test. Trapping exits lets the test observe and ignore
    %% these cleanly.
    process_flag(trap_exit, true),
    {ok, {ClientSock, ServerSock}} = socket_pair(),
    [{client_sock, ClientSock}, {server_sock, ServerSock} | Config].

end_per_testcase(_TC, Config) ->
    catch gen_tcp:close(?config(client_sock, Config)),
    catch gen_tcp:close(?config(server_sock, Config)),
    ok.

%% ----------------------------------------------------------------------------
%% Cases: basic
%% ----------------------------------------------------------------------------

simple_get(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, SId} = h1_connection:send_request(Client, <<"GET">>, <<"/">>,
                                           [{<<"host">>, <<"x">>}], #{}),
    %% Server side: receive request.
    Ev = receive_h1(Server, 1000),
    {request, SrvSId, <<"GET">>, <<"/">>, ReqHeaders} = Ev,
    ?assertEqual(<<"x">>, proplists:get_value(<<"host">>, ReqHeaders)),
    %% End-of-body marker.
    {data, SrvSId, <<>>, true} = receive_h1(Server, 1000),
    %% Respond.
    ok = h1_connection:send_response(Server, SrvSId, 200,
                                     [{<<"content-type">>, <<"text/plain">>}]),
    ok = h1_connection:send_data(Server, SrvSId, <<"hello">>, true),
    %% Client side: receive response.
    {response, SId, 200, RespHeaders} = receive_h1(Client, 1000),
    ?assertEqual(<<"text/plain">>, proplists:get_value(<<"content-type">>, RespHeaders)),
    {data, SId, <<"hello">>, _} = receive_h1(Client, 1000),
    stop_pair(Client, Server).

post_content_length(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, _} = h1_connection:send_request(Client, <<"POST">>, <<"/upload">>,
        [{<<"host">>, <<"x">>}, {<<"content-length">>, <<"5">>}],
        #{body => <<"hello">>, end_stream => true}),
    {request, SrvSId, <<"POST">>, <<"/upload">>, _} = receive_h1(Server, 1000),
    {data, SrvSId, <<"hello">>, _} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, SrvSId, 201,
                                     [{<<"content-length">>, <<"0">>}]),
    ok = h1_connection:send_data(Server, SrvSId, <<>>, true),
    {response, _, 201, _} = receive_h1(Client, 1000),
    stop_pair(Client, Server).

post_chunked(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, _} = h1_connection:send_request(Client, <<"POST">>, <<"/x">>,
        [{<<"host">>, <<"x">>}, {<<"transfer-encoding">>, <<"chunked">>}],
        #{body => <<"hello">>, end_stream => true}),
    {request, SrvSId, <<"POST">>, <<"/x">>, _} = receive_h1(Server, 1000),
    {data, SrvSId, <<"hello">>, _} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, SrvSId, 200, []),
    ok = h1_connection:send_data(Server, SrvSId, <<"ok">>, true),
    {response, _, 200, _} = receive_h1(Client, 1000),
    {data, _, <<"ok">>, _} = receive_h1(Client, 1000),
    stop_pair(Client, Server).

response_chunked(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, CSId} = h1_connection:send_request(Client, <<"GET">>, <<"/stream">>,
                                            [{<<"host">>, <<"x">>}], #{}),
    {request, SrvSId, <<"GET">>, <<"/stream">>, _} = receive_h1(Server, 1000),
    {data, SrvSId, <<>>, true} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, SrvSId, 200, []),
    ok = h1_connection:send_data(Server, SrvSId, <<"one">>, false),
    ok = h1_connection:send_data(Server, SrvSId, <<"two">>, false),
    ok = h1_connection:send_data(Server, SrvSId, <<"three">>, true),
    {response, CSId, 200, _} = receive_h1(Client, 1000),
    Chunks = collect_data(Client, CSId, []),
    ?assertEqual(<<"onetwothree">>, iolist_to_binary(Chunks)),
    stop_pair(Client, Server).

response_with_trailers(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, _CSId} = h1_connection:send_request(Client, <<"GET">>, <<"/t">>,
                                             [{<<"host">>, <<"x">>}], #{}),
    {request, SrvSId, _, _, _} = receive_h1(Server, 1000),
    {data, SrvSId, <<>>, true} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, SrvSId, 200,
        [{<<"transfer-encoding">>, <<"chunked">>},
         {<<"trailer">>, <<"x-checksum">>}]),
    ok = h1_connection:send_data(Server, SrvSId, <<"hi">>, false),
    ok = h1_connection:send_trailers(Server, SrvSId,
                                     [{<<"x-checksum">>, <<"abc">>}]),
    {response, _, 200, _} = receive_h1(Client, 1000),
    Chunks = collect_data_until_end(Client, []),
    ?assertEqual(<<"hi">>, iolist_to_binary(Chunks)),
    stop_pair(Client, Server).

%% ----------------------------------------------------------------------------
%% Cases: keepalive
%% ----------------------------------------------------------------------------

keep_alive_two_requests(Config) ->
    {Client, Server} = start_pair(Config),
    do_request(Client, Server, <<"/a">>, <<"A">>),
    do_request(Client, Server, <<"/b">>, <<"B">>),
    stop_pair(Client, Server).

pipelined_two_requests(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, S1} = h1_connection:send_request(Client, <<"GET">>, <<"/a">>,
                                          [{<<"host">>, <<"x">>}], #{}),
    {ok, S2} = h1_connection:send_request(Client, <<"GET">>, <<"/b">>,
                                          [{<<"host">>, <<"x">>}], #{}),
    %% Server reads first request.
    {request, Sr1, <<"GET">>, <<"/a">>, _} = receive_h1(Server, 1000),
    {data, Sr1, <<>>, true} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, Sr1, 200, []),
    ok = h1_connection:send_data(Server, Sr1, <<"A">>, true),
    %% Then second.
    {request, Sr2, <<"GET">>, <<"/b">>, _} = receive_h1(Server, 1000),
    {data, Sr2, <<>>, true} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, Sr2, 200, []),
    ok = h1_connection:send_data(Server, Sr2, <<"B">>, true),
    %% Client sees both responses in order.
    {response, S1, 200, _} = receive_h1(Client, 1000),
    {data, S1, <<"A">>, _} = receive_h1(Client, 1000),
    {response, S2, 200, _} = receive_h1(Client, 1000),
    {data, S2, <<"B">>, _} = receive_h1(Client, 1000),
    stop_pair(Client, Server).

server_connection_close(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, _} = h1_connection:send_request(Client, <<"GET">>, <<"/">>,
                                         [{<<"host">>, <<"x">>},
                                          {<<"connection">>, <<"close">>}], #{}),
    {request, SrvSId, _, _, _} = receive_h1(Server, 1000),
    {data, SrvSId, <<>>, true} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, SrvSId, 200, []),
    ok = h1_connection:send_data(Server, SrvSId, <<"bye">>, true),
    {response, _, 200, _} = receive_h1(Client, 1000),
    {data, _, <<"bye">>, _} = receive_h1(Client, 1000),
    %% At this point server should advertise close and shut socket;
    %% client should emit {closed, _}.
    receive_closed(Client, 1000),
    receive_closed(Server, 1000),
    ok.

client_closes_on_connection_close(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, _} = h1_connection:send_request(Client, <<"GET">>, <<"/">>,
                                         [{<<"host">>, <<"x">>}], #{}),
    {request, SrvSId, _, _, _} = receive_h1(Server, 1000),
    {data, SrvSId, <<>>, true} = receive_h1(Server, 1000),
    %% Server responds with Connection: close.
    ok = h1_connection:send_response(Server, SrvSId, 200,
                                     [{<<"connection">>, <<"close">>}]),
    ok = h1_connection:send_data(Server, SrvSId, <<"done">>, true),
    {response, _, 200, _} = receive_h1(Client, 1000),
    {data, _, <<"done">>, _} = receive_h1(Client, 1000),
    ok.

%% ----------------------------------------------------------------------------
%% Cases: expect
%% ----------------------------------------------------------------------------

expect_100_continue(Config) ->
    {Client, Server} = start_pair(Config),
    {ok, CSId} = h1_connection:send_request(Client, <<"POST">>, <<"/x">>,
        [{<<"host">>, <<"x">>},
         {<<"expect">>, <<"100-continue">>},
         {<<"content-length">>, <<"5">>}],
        #{body => <<"hello">>, end_stream => true}),
    {request, Sr, <<"POST">>, _, ReqHs} = receive_h1(Server, 1000),
    ?assertEqual(<<"100-continue">>, proplists:get_value(<<"expect">>, ReqHs)),
    ok = h1_connection:continue(Server, Sr),
    %% Client sees 100 as informational.
    {informational, CSId, 100, _} = receive_h1(Client, 1000),
    %% Body flows afterwards.
    {data, Sr, <<"hello">>, _} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, Sr, 200, []),
    ok = h1_connection:send_data(Server, Sr, <<"ok">>, true),
    {response, CSId, 200, _} = receive_h1(Client, 1000),
    stop_pair(Client, Server).

%% ----------------------------------------------------------------------------
%% Cases: upgrade
%% ----------------------------------------------------------------------------

upgrade_server_side(Config) ->
    %% Drive the server directly with raw bytes to test the upgrade detection.
    ServerSock = ?config(server_sock, Config),
    ClientSock = ?config(client_sock, Config),
    {ok, Server} = h1_connection:start_link(server, ServerSock,
                                            self(), #{}),
    ok = gen_tcp:controlling_process(ServerSock, Server),
    ok = h1_connection:activate(Server),
    receive {h1, Server, connected} -> ok after 1000 -> ct:fail(no_connected) end,
    %% Send raw upgrade request.
    Req = <<"GET / HTTP/1.1\r\nHost: x\r\n",
            "Connection: Upgrade\r\nUpgrade: connect-udp\r\n\r\n">>,
    ok = gen_tcp:send(ClientSock, Req),
    %% Expect {upgrade, ...} event on server's owner.
    Ev = receive {h1, Server, E} -> E after 1000 -> ct:fail(no_upgrade) end,
    {upgrade, SrvSId, <<"connect-udp">>, <<"GET">>, <<"/">>, _Hs} = Ev,
    %% Accept. The call replies with the socket + any buffered bytes.
    {ok, AcceptedSock, _Buf} =
        h1_connection:accept_upgrade(Server, SrvSId, []),
    ?assertEqual(ServerSock, AcceptedSock),
    %% Pull bytes off the handed-back socket.
    ok = inet:setopts(ClientSock, [{active, false}]),
    {ok, Resp} = gen_tcp:recv(ClientSock, 0, 1000),
    ?assertMatch(<<"HTTP/1.1 101 Switching Protocols", _/binary>>, Resp),
    ok.

upgrade_client_side(Config) ->
    %% Drive the client with raw server bytes.
    ClientSock = ?config(client_sock, Config),
    ServerSock = ?config(server_sock, Config),
    {ok, Client} = h1_connection:start_link(client, ClientSock, self(), #{}),
    ok = gen_tcp:controlling_process(ClientSock, Client),
    ok = h1_connection:activate(Client),
    receive {h1, Client, connected} -> ok after 1000 -> ct:fail(no_connected) end,
    Self = self(),
    UpgradePid = spawn(fun() ->
        R = h1_connection:upgrade(Client, <<"connect-udp">>,
                                  [{<<"host">>, <<"ex">>}]),
        Self ! {upgrade_result, R}
    end),
    _ = UpgradePid,
    %% Read the request the client emitted.
    ok = inet:setopts(ServerSock, [{active, false}]),
    {ok, ReqBin} = gen_tcp:recv(ServerSock, 0, 1000),
    ?assertMatch(<<"GET / HTTP/1.1", _/binary>>, ReqBin),
    %% Reply 101.
    Resp = <<"HTTP/1.1 101 Switching Protocols\r\n",
             "Connection: Upgrade\r\nUpgrade: connect-udp\r\n\r\nTAILDATA">>,
    ok = gen_tcp:send(ServerSock, Resp),
    %% Collect the result.
    UpgradeResult = receive
        {upgrade_result, R} -> R
    after 2000 -> ct:fail(no_upgrade_result)
    end,
    {ok, _Id, HandedBack, Buffer, _Hs} = UpgradeResult,
    ?assertEqual(ClientSock, HandedBack),
    ?assertEqual(<<"TAILDATA">>, Buffer),
    ok.

upgrade_capsule_exchange(Config) ->
    %% End-to-end: client upgrades, then both sides use h1_capsule to
    %% ferry a DATAGRAM capsule each way over the raw socket.
    ClientSock = ?config(client_sock, Config),
    ServerSock = ?config(server_sock, Config),
    {ok, Client} = h1_connection:start_link(client, ClientSock, self(), #{}),
    ok = gen_tcp:controlling_process(ClientSock, Client),
    ok = h1_connection:activate(Client),
    receive {h1, Client, connected} -> ok after 1000 -> ct:fail(no_connected) end,

    %% Spawn an actor to drive the upgrade call synchronously; after it
    %% receives the socket it must transfer ownership back to the test
    %% process BEFORE exiting, otherwise the socket is closed when the
    %% spawn exits.
    Parent = self(),
    spawn(fun() ->
        R = h1_connection:upgrade(Client, <<"connect-udp">>,
                                  [{<<"host">>, <<"ex">>}]),
        case R of
            {ok, _Id, Sock, _Buf, _Hs} ->
                gen_tcp:controlling_process(Sock, Parent);
            _ -> ok
        end,
        Parent ! {upgrade_result, R},
        %% Stay alive until parent says we can exit, in case the caller
        %% hasn't taken ownership yet.
        receive done -> ok after 5000 -> ok end
    end),

    ok = inet:setopts(ServerSock, [{active, false}]),
    {ok, _ReqBin} = gen_tcp:recv(ServerSock, 0, 1000),
    ServerCapsule = h1_capsule:encode(datagram, <<"from-server">>),
    Reply = iolist_to_binary(
        [<<"HTTP/1.1 101 Switching Protocols\r\n",
           "Connection: Upgrade\r\nUpgrade: connect-udp\r\n\r\n">>,
         ServerCapsule]),
    ok = gen_tcp:send(ServerSock, Reply),

    {ok, _Id, Sock, Buf, _Hs} =
        receive {upgrade_result, Res} -> Res after 2000 -> ct:fail(no_upgrade) end,

    %% Parse the buffered capsule.
    {ok, {datagram, <<"from-server">>}, <<>>} = h1_capsule:decode(Buf),

    %% Now send a client-originated capsule and read it on the server side.
    ClientCapsule = h1_capsule:encode(datagram, <<"from-client">>),
    ok = gen_tcp:send(Sock, ClientCapsule),
    {ok, Received} = gen_tcp:recv(ServerSock, byte_size(ClientCapsule), 1000),
    {ok, {datagram, <<"from-client">>}, <<>>} = h1_capsule:decode(Received),
    ok.

%% ----------------------------------------------------------------------------
%% Cases: hardening (review batch)
%% ----------------------------------------------------------------------------

idle_timeout_closes_silent_connection(Config) ->
    ClientSock = ?config(client_sock, Config),
    {ok, Client} = h1_connection:start_link(
        client, ClientSock, self(), #{idle_timeout => 100}),
    ok = gen_tcp:controlling_process(ClientSock, Client),
    ok = h1_connection:activate(Client),
    %% No data → idle timer should fire and stop the connection.
    %% terminate/3 emits a `{closed, Reason}' event with the stop reason.
    ok = wait_for_closed(Client, idle_timeout, 2000),
    catch h1_connection:close(Client).

wait_for_closed(Conn, Tag, Timeout) ->
    receive
        {h1, Conn, connected} -> wait_for_closed(Conn, Tag, Timeout);
        {h1, Conn, {closed, Tag}} -> ok;
        {h1, Conn, {closed, {shutdown, Tag}}} -> ok
    after Timeout -> ct:fail({no_closed, Tag, flush_messages()})
    end.

pipeline_disabled_returns_error(Config) ->
    ClientSock = ?config(client_sock, Config),
    ServerSock = ?config(server_sock, Config),
    {ok, Client} = h1_connection:start_link(
        client, ClientSock, self(), #{pipeline => false}),
    {ok, Server} = h1_connection:start_link(
        server, ServerSock, self(), #{}),
    ok = gen_tcp:controlling_process(ClientSock, Client),
    ok = gen_tcp:controlling_process(ServerSock, Server),
    ok = h1_connection:activate(Client),
    ok = h1_connection:activate(Server),
    {ok, _} = h1_connection:send_request(Client, <<"GET">>, <<"/a">>,
                                         [{<<"host">>, <<"x">>}], #{}),
    %% Second request while first is in flight → rejected.
    ?assertEqual({error, pipeline_disabled},
                 h1_connection:send_request(Client, <<"GET">>, <<"/b">>,
                                            [{<<"host">>, <<"x">>}], #{})),
    stop_pair(Client, Server).

client_auto_adds_host_header(Config) ->
    ClientSock = ?config(client_sock, Config),
    ServerSock = ?config(server_sock, Config),
    {ok, Client} = h1_connection:start_link(
        client, ClientSock, self(), #{peer_host => <<"example.test">>}),
    {ok, Server} = h1_connection:start_link(
        server, ServerSock, self(), #{}),
    ok = gen_tcp:controlling_process(ClientSock, Client),
    ok = gen_tcp:controlling_process(ServerSock, Server),
    ok = h1_connection:activate(Client),
    ok = h1_connection:activate(Server),
    receive {h1, Client, connected} -> ok after 1000 -> ct:fail(no_client_connected) end,
    receive {h1, Server, connected} -> ok after 1000 -> ct:fail(no_server_connected) end,
    {ok, _} = h1_connection:send_request(Client, <<"GET">>, <<"/x">>,
                                         [], #{}),
    {request, _, <<"GET">>, <<"/x">>, Hs} = receive_h1(Server, 1000),
    ?assertEqual(<<"example.test">>,
                 proplists:get_value(<<"host">>, Hs)),
    stop_pair(Client, Server).

server_rejects_1_1_request_without_host_with_400(Config) ->
    ServerSock = ?config(server_sock, Config),
    ClientSock = ?config(client_sock, Config),
    {ok, Server} = h1_connection:start_link(server, ServerSock, self(), #{}),
    ok = gen_tcp:controlling_process(ServerSock, Server),
    ok = h1_connection:activate(Server),
    ok = gen_tcp:send(ClientSock, <<"GET / HTTP/1.1\r\n\r\n">>),
    ok = inet:setopts(ClientSock, [{active, false}]),
    {ok, Resp} = gen_tcp:recv(ClientSock, 0, 1000),
    ?assertMatch(<<"HTTP/1.1 400 ", _/binary>>, Resp),
    ?assertMatch({match, _}, re:run(Resp, <<"(?i)connection: close">>)),
    catch h1_connection:close(Server).

close_delimited_response_terminates_on_eof(Config) ->
    ClientSock = ?config(client_sock, Config),
    ServerSock = ?config(server_sock, Config),
    {ok, Client} = h1_connection:start_link(client, ClientSock, self(), #{}),
    ok = gen_tcp:controlling_process(ClientSock, Client),
    ok = h1_connection:activate(Client),
    receive {h1, Client, connected} -> ok after 1000 -> ct:fail(no_connected) end,
    {ok, _} = h1_connection:send_request(Client, <<"GET">>, <<"/">>,
                                         [{<<"host">>, <<"x">>}], #{}),
    %% Consume the request bytes off the server socket.
    ok = inet:setopts(ServerSock, [{active, false}]),
    {ok, _} = gen_tcp:recv(ServerSock, 0, 1000),
    %% Server writes a response with no Content-Length / Transfer-Encoding,
    %% then closes the socket to delimit the body.
    Resp = <<"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n",
             "streaming payload">>,
    ok = gen_tcp:send(ServerSock, Resp),
    ok = gen_tcp:close(ServerSock),
    %% Client should see headers, then body chunks, then a final
    %% empty-data end marker plus the closed event.
    {response, _, 200, _} = receive_h1(Client, 1000),
    Body = collect_body(Client, <<>>),
    ?assertEqual(<<"streaming payload">>, Body),
    catch h1_connection:close(Client).

collect_body(Conn, Acc) ->
    receive
        {h1, Conn, {data, _, D, false}} -> collect_body(Conn, <<Acc/binary, D/binary>>);
        {h1, Conn, {data, _, D, true}}  -> <<Acc/binary, D/binary>>;
        {h1, Conn, {closed, _}}         -> Acc;
        {'EXIT', Conn, _}               -> Acc
    after 1000 -> Acc
    end.

flush_messages() ->
    receive M -> [M | flush_messages()] after 0 -> [] end.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

%% Listen on 127.0.0.1:0, connect, accept — gives a {ClientSock, ServerSock}
%% pair owned by the current process.
socket_pair() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                 {packet, raw}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    {ok, Client} = gen_tcp:connect({127, 0, 0, 1}, Port,
                                   [binary, {active, false}, {packet, raw}]),
    {ok, Server} = gen_tcp:accept(L, 1000),
    gen_tcp:close(L),
    {ok, {Client, Server}}.

start_pair(Config) ->
    ClientSock = ?config(client_sock, Config),
    ServerSock = ?config(server_sock, Config),
    {ok, Client} = h1_connection:start_link(client, ClientSock, self(), #{}),
    ok = gen_tcp:controlling_process(ClientSock, Client),
    {ok, Server} = h1_connection:start_link(server, ServerSock, self(), #{}),
    ok = gen_tcp:controlling_process(ServerSock, Server),
    ok = h1_connection:activate(Client),
    ok = h1_connection:activate(Server),
    receive {h1, Client, connected} -> ok after 1000 -> ct:fail(no_connected_client) end,
    receive {h1, Server, connected} -> ok after 1000 -> ct:fail(no_connected_server) end,
    {Client, Server}.

stop_pair(Client, Server) ->
    catch h1_connection:close(Client),
    catch h1_connection:close(Server),
    %% Drain any final {closed, _} notifications to avoid leaking messages
    %% into the next test.
    flush_h1(),
    ok.

flush_h1() ->
    receive {h1, _, _} -> flush_h1() after 20 -> ok end.

receive_h1(Conn, Timeout) ->
    receive {h1, Conn, Ev} -> Ev
    after Timeout -> ct:fail({no_event, process_info(self(), messages)})
    end.

receive_closed(Conn, Timeout) ->
    receive {h1, Conn, {closed, _}} -> ok
    after Timeout -> ct:fail(no_closed)
    end.

collect_data(Conn, SId, Acc) ->
    receive
        {h1, Conn, {data, SId, Data, true}} ->
            lists:reverse([Data | Acc]);
        {h1, Conn, {data, SId, Data, false}} ->
            collect_data(Conn, SId, [Data | Acc])
    after 1000 ->
        ct:fail({incomplete_body, lists:reverse(Acc)})
    end.

collect_data_until_end(Conn, Acc) ->
    receive
        {h1, Conn, {data, _, <<>>, true}} -> lists:reverse(Acc);
        {h1, Conn, {data, _, Data, true}} -> lists:reverse([Data | Acc]);
        {h1, Conn, {data, _, Data, false}} ->
            collect_data_until_end(Conn, [Data | Acc]);
        {h1, Conn, {trailers, _, _}} ->
            lists:reverse(Acc)
    after 1000 ->
        ct:fail({incomplete_body, lists:reverse(Acc)})
    end.

do_request(Client, Server, Path, Body) ->
    {ok, CSId} = h1_connection:send_request(Client, <<"GET">>, Path,
                                            [{<<"host">>, <<"x">>}], #{}),
    {request, SSId, <<"GET">>, Path, _} = receive_h1(Server, 1000),
    {data, SSId, <<>>, true} = receive_h1(Server, 1000),
    ok = h1_connection:send_response(Server, SSId, 200, []),
    ok = h1_connection:send_data(Server, SSId, Body, true),
    {response, CSId, 200, _} = receive_h1(Client, 1000),
    {data, CSId, Body, _} = receive_h1(Client, 1000),
    ok.
