%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc End-to-end tests for HTTP/1.1 Upgrade + RFC 9297 capsule
%%% passthrough over a real loopback TCP socket.
-module(h1_upgrade_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    upgrade_handshake/1,
    upgrade_capsule_exchange/1,
    upgrade_with_leftover_bytes/1,
    upgrade_with_path_pseudo_header/1,
    upgrade_wire_path_in_request_line/1,
    accept_upgrade_dedupes_framing_headers/1,
    http_1_0_upgrade_ignored/1,
    client_upgrade_refused_while_pending/1,
    client_request_refused_while_upgrade_pending/1,
    client_upgrade_after_responses/1,
    client_upgrade_refused_then_closed/1,
    client_upgrade_refused_kept_open/1,
    client_upgrade_waits_past_interim/1,
    upgrade_refused_by_h1_server/1
]).

all() ->
    [upgrade_handshake, upgrade_capsule_exchange, upgrade_with_leftover_bytes,
     upgrade_with_path_pseudo_header, upgrade_wire_path_in_request_line,
     accept_upgrade_dedupes_framing_headers, http_1_0_upgrade_ignored,
     client_upgrade_refused_while_pending,
     client_request_refused_while_upgrade_pending,
     client_upgrade_after_responses,
     client_upgrade_refused_then_closed,
     client_upgrade_refused_kept_open,
     client_upgrade_waits_past_interim,
     upgrade_refused_by_h1_server].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    application:stop(h1),
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
%% Server handler that accepts any Upgrade and echoes subsequent capsules
%% ----------------------------------------------------------------------------

echo_upgrade_handler(Test) ->
    fun(Conn, StreamId, _Method, _Path, Headers) ->
        case proplists:get_value(<<"upgrade">>, Headers) of
            undefined ->
                h1:send_response(Conn, StreamId, 400,
                    [{<<"content-length">>, <<"0">>}]),
                h1:send_data(Conn, StreamId, <<>>, true);
            Proto ->
                case h1:accept_upgrade(Conn, StreamId,
                                       [{<<"x-proto">>, Proto}]) of
                    {ok, Sock, Buf} ->
                        Test ! {server_upgraded, Proto, Sock, Buf},
                        echo_capsule_loop(Sock, Buf);
                    {error, R} ->
                        Test ! {server_upgrade_error, R}
                end
        end
    end.

echo_capsule_loop(Sock, Buf) ->
    case h1_upgrade:recv_capsule(gen_tcp, Sock, Buf, 2000) of
        {ok, {Type, Payload}, Rest} ->
            ok = h1_upgrade:send_capsule(gen_tcp, Sock, Type,
                                          <<"echo:", Payload/binary>>),
            echo_capsule_loop(Sock, Rest);
        {error, _} ->
            h1_upgrade:close(gen_tcp, Sock)
    end.

%% ----------------------------------------------------------------------------
%% Tests
%% ----------------------------------------------------------------------------

upgrade_handshake(Config0) ->
    Config = start_server(echo_upgrade_handler(self()), Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, _Id, Sock, Buf, RespHeaders} =
        h1:upgrade(Conn, <<"connect-udp">>,
                   [{<<"host">>, <<"localhost">>}]),
    ?assertEqual(<<>>, Buf),
    ?assertEqual(<<"connect-udp">>,
                 proplists:get_value(<<"x-proto">>, RespHeaders)),
    %% Server side should have received its upgrade event.
    receive {server_upgraded, <<"connect-udp">>, _SSock, _SBuf} -> ok
    after 2000 -> ct:fail(no_server_upgrade)
    end,
    gen_tcp:close(Sock),
    ok.

upgrade_capsule_exchange(Config0) ->
    Config = start_server(echo_upgrade_handler(self()), Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, _Id, Sock, Buf, _Hs} =
        h1:upgrade(Conn, <<"connect-udp">>,
                   [{<<"host">>, <<"localhost">>}]),
    %% Client sends a capsule.
    ok = h1_upgrade:send_capsule(gen_tcp, Sock, datagram, <<"ping">>),
    {ok, {datagram, <<"echo:ping">>}, Buf1} =
        h1_upgrade:recv_capsule(gen_tcp, Sock, Buf, 2000),
    %% And another, reusing the leftover buffer.
    ok = h1_upgrade:send_capsule(gen_tcp, Sock, datagram, <<"pong">>),
    {ok, {datagram, <<"echo:pong">>}, _} =
        h1_upgrade:recv_capsule(gen_tcp, Sock, Buf1, 2000),
    gen_tcp:close(Sock),
    ok.

upgrade_with_leftover_bytes(Config0) ->
    %% Server writes a capsule together with the 101 response so the
    %% client sees it as leftover Buffer on the handed-back socket.
    Parent = self(),
    Handler = fun(Conn, StreamId, _M, _P, _Headers) ->
        {ok, Sock, _Buf} = h1:accept_upgrade(Conn, StreamId, []),
        ok = h1_upgrade:send_capsule(gen_tcp, Sock, datagram, <<"hello">>),
        Parent ! {server_done, Sock},
        receive go_close -> gen_tcp:close(Sock) after 2000 -> ok end
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, _Id, Sock, Buf, _Hs} =
        h1:upgrade(Conn, <<"connect-udp">>,
                   [{<<"host">>, <<"localhost">>}]),
    {ok, {datagram, Payload}, <<>>} =
        h1_upgrade:recv_capsule(gen_tcp, Sock, Buf, 2000),
    ?assertEqual(<<"hello">>, Payload),
    receive {server_done, _SSock} -> ok after 2000 -> ct:fail(no_server_done) end,
    gen_tcp:close(Sock),
    ok.

%% Regression: h1:upgrade/4 crashed with {invalid_header_name, <<":path">>}
%% when a caller passed the documented `:path' pseudo-header. The eager
%% dead-code Wire block in handle_client_upgrade/4 encoded the full header
%% list before upgrade_wire/1 stripped the pseudo-header.
upgrade_with_path_pseudo_header(Config0) ->
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        {ok, _Sock, _Buf} = h1:accept_upgrade(Conn, StreamId, []),
        ok
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    Result = h1:upgrade(Conn, <<"demo">>,
                        [{<<":path">>, <<"/some/deep/path">>},
                         {<<"host">>, <<"localhost">>}], 5000),
    ?assertMatch({ok, _Id, _Sock, _Buf, _RespHs}, Result),
    {ok, _Id, Sock, _Buf, RespHs} = Result,
    ?assertEqual(<<"demo">>,
                 proplists:get_value(<<"upgrade">>, RespHs)),
    gen_tcp:close(Sock),
    ok.

%% Wire-shape regression: :path must land in the request-line, not as a
%% header. Uses a raw TCP listener (no h1 server) to capture the exact
%% bytes the client writes.
upgrade_wire_path_in_request_line(_Config) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                 {ip, {127,0,0,1}}, {packet, raw}]),
    {ok, Port} = inet:port(L),
    Parent = self(),
    spawn_link(fun() ->
        {ok, Sock} = gen_tcp:accept(L, 5000),
        gen_tcp:close(L),
        Bytes = recv_until_headers(Sock),
        Parent ! {raw_request, Bytes},
        %% Reply with a well-formed 101 so the client does not hang.
        Resp = <<"HTTP/1.1 101 Switching Protocols\r\n"
                 "Connection: Upgrade\r\n"
                 "Upgrade: demo\r\n\r\n">>,
        gen_tcp:send(Sock, Resp),
        receive stop -> gen_tcp:close(Sock) after 5000 -> ok end
    end),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    _ = h1:upgrade(Conn, <<"demo">>,
                   [{<<":path">>, <<"/some/deep/path">>},
                    {<<"host">>, <<"localhost">>}], 5000),
    Bytes = receive {raw_request, B} -> B after 5000 -> ct:fail(no_bytes) end,
    [Line1 | _] = binary:split(Bytes, <<"\r\n">>),
    ?assertEqual(<<"GET /some/deep/path HTTP/1.1">>, Line1),
    Lower = string:lowercase(Bytes),
    ?assert(binary:match(Lower, <<"upgrade: demo">>) =/= nomatch),
    ?assert(binary:match(Lower, <<"connection: upgrade">>) =/= nomatch),
    %% :path must NOT appear as a header line.
    ?assertEqual(nomatch, binary:match(Bytes, <<":path">>)),
    ok.

%% Regression: accept_upgrade/3 prepended its framing headers without
%% checking ExtraHeaders, so a caller passing connection/upgrade (any
%% case) produced a 101 with each header twice. Spec-strict WebSocket
%% clients (Safari, undici) reject the handshake on the duplicates.
%% Raw client socket so we can count the exact header lines written.
accept_upgrade_dedupes_framing_headers(Config0) ->
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        {ok, Sock, _Buf} = h1:accept_upgrade(Conn, StreamId,
            [{<<"Connection">>, <<"Upgrade">>},
             {<<"UPGRADE">>, <<"websocket">>},
             {<<"sec-websocket-accept">>, <<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>}]),
        receive go_close -> gen_tcp:close(Sock) after 2000 -> ok end
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock,
        <<"GET /chat HTTP/1.1\r\n"
          "host: localhost\r\n"
          "connection: Upgrade\r\n"
          "upgrade: websocket\r\n\r\n">>),
    Bytes = recv_until_headers(Sock),
    [Head | _] = binary:split(Bytes, <<"\r\n\r\n">>),
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    ?assertMatch(<<"HTTP/1.1 101 ", _/binary>>, StatusLine),
    Headers = [begin
                   [N, V] = binary:split(L, <<":">>),
                   {string:lowercase(N), string:trim(V)}
               end || L <- HeaderLines],
    ?assertEqual([<<"Upgrade">>],
                 [V || {<<"connection">>, V} <- Headers]),
    ?assertEqual([<<"websocket">>],
                 [V || {<<"upgrade">>, V} <- Headers]),
    ?assertEqual([<<"s3pPLMBiTxaQ9kYGzzhZRbK+xOo=">>],
                 [V || {<<"sec-websocket-accept">>, V} <- Headers]),
    gen_tcp:close(Sock),
    ok.

%% RFC 9110 §7.8: "A server that receives an Upgrade header field in an
%% HTTP/1.0 request MUST ignore that Upgrade field." HTTP/1.0 has no
%% Upgrade mechanism, and an HTTP/1.0 intermediary may have forwarded the
%% field without understanding it. The same request in HTTP/1.1 still
%% upgrades. The handler can tell the versions apart with
%% `h1:request_version/2' (the `{request, ...}' event carries only
%% method, path and headers), which is how a downstream listener such as
%% masque answers 400 instead of serving the tunnel.
http_1_0_upgrade_ignored(Config0) ->
    Test = self(),
    Handler = fun(Conn, StreamId, _M, _P, Headers) ->
        Version = h1:request_version(Conn, StreamId),
        Upgrade = proplists:get_value(<<"upgrade">>, Headers),
        %% Ask to upgrade whatever the version: the server must refuse
        %% on HTTP/1.0 even when the handler asks.
        case h1:accept_upgrade(Conn, StreamId, []) of
            {ok, Sock, _Buf} ->
                Test ! {handler, Version, Upgrade, upgraded},
                receive done -> ok after 3000 -> ok end,
                gen_tcp:close(Sock);
            {error, R} ->
                Test ! {handler, Version, Upgrade, {error, R}},
                h1:send_response(Conn, StreamId, 200,
                                 [{<<"content-length">>, <<"5">>}]),
                h1:send_data(Conn, StreamId, <<"plain">>, true)
        end
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    Req = fun(Version) ->
        <<"GET /tunnel HTTP/", Version/binary, "\r\n"
          "host: localhost\r\n"
          "connection: Upgrade\r\n"
          "upgrade: connect-udp\r\n\r\n">>
    end,

    %% HTTP/1.0: a plain request. The `Upgrade' field is ignored — it is
    %% dropped from the headers the handler sees, `accept_upgrade/3'
    %% refuses, and the answer is a 200, not a 101.
    {ok, Sock10} = gen_tcp:connect("127.0.0.1", Port,
                                   [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock10, Req(<<"1.0">>)),
    ?assertMatch({200, _, <<"plain">>}, recv_http_response(Sock10)),
    receive
        {handler, V10, U10, R10} ->
            ?assertEqual({ok, {1, 0}}, V10),
            ?assertEqual(undefined, U10),
            ?assertEqual({error, no_upgrade_header}, R10)
    after 3000 -> ct:fail(no_handler_10)
    end,
    gen_tcp:close(Sock10),

    %% HTTP/1.1: the identical request still upgrades — the handler sees
    %% the `Upgrade' header, the version is 1.1, and the 101 goes out.
    {ok, Sock11} = gen_tcp:connect("127.0.0.1", Port,
                                   [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock11, Req(<<"1.1">>)),
    ?assertMatch(<<"HTTP/1.1 101 ", _/binary>>, recv_until_headers(Sock11)),
    receive
        {handler, V11, U11, R11} ->
            ?assertEqual({ok, {1, 1}}, V11),
            ?assertEqual(<<"connect-udp">>, U11),
            ?assertEqual(upgraded, R11)
    after 3000 -> ct:fail(no_handler_11)
    end,
    Test ! done,
    gen_tcp:close(Sock11),
    ok.

recv_http_response(Sock) ->
    [Head, Rest] = binary:split(recv_until_headers(Sock), <<"\r\n\r\n">>),
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_Version, StatusBin | _] = binary:split(StatusLine, <<" ">>, [global]),
    Hdrs = [begin
                [N, V] = binary:split(L, <<":">>),
                {string:lowercase(N), string:trim(V)}
            end || L <- HeaderLines],
    CL = binary_to_integer(proplists:get_value(<<"content-length">>, Hdrs, <<"0">>)),
    {binary_to_integer(StatusBin), Hdrs, recv_body(Sock, Rest, CL)}.

recv_body(_Sock, Acc, CL) when byte_size(Acc) >= CL ->
    binary:part(Acc, 0, CL);
recv_body(Sock, Acc, CL) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_body(Sock, <<Acc/binary, Data/binary>>, CL);
        {error, R} -> ct:fail({recv_body, R})
    end.

recv_until_headers(Sock) ->
    recv_until_headers(Sock, <<>>).
recv_until_headers(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Bin} -> recv_until_headers(Sock, <<Acc/binary, Bin/binary>>);
                {error, R} -> ct:fail({recv_until_headers, R})
            end;
        _ -> Acc
    end.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

start_server(Handler, Config) ->
    Opts = #{transport => tcp, handler => Handler, acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    [{server_ref, Ref} | Config].

%% ----------------------------------------------------------------------------
%% Client upgrade on a busy connection
%% ----------------------------------------------------------------------------
%%
%% The h1 client talks to a raw gen_tcp server held by the test, so the
%% exact bytes it writes are visible.

%% An upgrade while a response is still arriving is refused and writes
%% nothing: it would take over the parser and corrupt that response. The
%% response is then read whole.
client_upgrade_refused_while_pending(_Config) ->
    {Conn, Srv} = raw_client(),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
    _ = recv_until_headers(Srv),
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 200 OK\r\ncontent-length: 6\r\n\r\nabc">>),
    ?assertMatch({response, Id, 200, _}, conn_event(Conn)),
    ?assertEqual({data, Id, <<"abc">>, false}, conn_event(Conn)),
    ?assertEqual({error, requests_pending},
                 h1:upgrade(Conn, <<"demo">>, [], 1000)),
    timer:sleep(50),
    ok = gen_tcp:send(Srv, <<"def">>),
    ?assertEqual({data, Id, <<"def">>, true}, conn_event(Conn)),
    %% Nothing was written after the first request.
    ?assertEqual({error, timeout}, gen_tcp:recv(Srv, 0, 300)),
    h1:close(Conn),
    gen_tcp:close(Srv).

%% A request while an upgrade waits for its answer is refused: once the
%% server switches protocols, its bytes would belong to the new protocol
%% (RFC 9110 §7.8). The upgrade then completes as usual.
client_request_refused_while_upgrade_pending(_Config) ->
    {Conn, Srv} = raw_client(),
    Test = self(),
    spawn_link(fun() ->
        Test ! {upgraded, h1:upgrade(Conn, <<"demo">>, [], 5000)}
    end),
    Request = recv_until_headers(Srv),
    ?assertNotEqual(nomatch, binary:match(string:lowercase(Request),
                                          <<"upgrade: demo">>)),
    ?assertEqual({error, upgrade_pending},
                 h1:request(Conn, <<"GET">>, <<"/b">>, [])),
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 101 Switching Protocols\r\n"
                             "connection: upgrade\r\nupgrade: demo\r\n\r\n">>),
    receive {upgraded, Result} -> ?assertMatch({ok, _, _, _, _}, Result)
    after 5000 -> ct:fail(no_upgrade)
    end,
    %% The refused request never reached the server. The process that took
    %% the socket has exited, so it may already be closed.
    ?assertNotMatch({ok, _}, gen_tcp:recv(Srv, 0, 300)),
    gen_tcp:close(Srv).

%% Once the earlier response has been read, the connection is idle and the
%% upgrade goes through on it.
client_upgrade_after_responses(_Config) ->
    {Conn, Srv} = raw_client(),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
    _ = recv_until_headers(Srv),
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 200 OK\r\ncontent-length: 1\r\n\r\na">>),
    ?assertMatch({response, Id, 200, _}, conn_event(Conn)),
    ?assertEqual({data, Id, <<"a">>, true}, conn_event(Conn)),
    Test = self(),
    spawn_link(fun() ->
        Test ! {upgraded, h1:upgrade(Conn, <<"demo">>, [], 5000)}
    end),
    _ = recv_until_headers(Srv),
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 101 Switching Protocols\r\n"
                             "connection: upgrade\r\nupgrade: demo\r\n\r\n">>),
    receive {upgraded, Result} -> ?assertMatch({ok, _, _, _, _}, Result)
    after 5000 -> ct:fail(no_upgrade)
    end,
    gen_tcp:close(Srv).

%% ----------------------------------------------------------------------------
%% Client upgrade refused by the server
%% ----------------------------------------------------------------------------
%%
%% RFC 9110 §7.8: a server that does not switch answers with a final status
%% other than 101 and the connection stays HTTP/1.1. upgrade/3,4 returns
%% `{error, {http_status, Status, Headers}}' as soon as that status arrives,
%% and the response is still delivered to the owner as for any request.

%% A proxy that refuses the tunnel closes after its answer (RFC 9931). The
%% caller, here the owner as in masque, gets the status and not
%% `{shutdown, peer_closed}', and the body is still delivered.
client_upgrade_refused_then_closed(_Config) ->
    {Conn, Srv} = raw_client(),
    Body = <<"no route to target">>,
    spawn_link(fun() ->
        _ = recv_until_headers(Srv),
        ok = gen_tcp:send(Srv, [<<"HTTP/1.1 502 Bad Gateway\r\n"
                                  "connection: close\r\n"
                                  "content-length: ">>,
                                integer_to_binary(byte_size(Body)),
                                <<"\r\n\r\n">>, Body]),
        gen_tcp:close(Srv)
    end),
    Result = h1:upgrade(Conn, <<"connect-udp">>, []),
    ?assertMatch({error, {http_status, 502, _}}, Result),
    {error, {http_status, 502, Hs}} = Result,
    ?assertEqual(<<"close">>, proplists:get_value(<<"connection">>, Hs)),
    {Id, 502} = response_event(Conn),
    ?assertEqual(Body, body_events(Conn, Id)),
    ?assertMatch({closed, _}, conn_event(Conn)).

%% A server that refuses and keeps the connection open: the caller returns
%% at once instead of waiting for its timeout. The owner need not read the
%% refusal body first: a request sent right after is answered on the same
%% connection, behind the refusal.
client_upgrade_refused_kept_open(_Config) ->
    {Conn, Srv} = raw_client(),
    Test = self(),
    spawn_link(fun() ->
        Test ! {upgrade_result, h1:upgrade(Conn, <<"connect-udp">>, [])}
    end),
    _ = recv_until_headers(Srv),
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 403 Forbidden\r\n"
                             "content-length: 9\r\n\r\nforbidden">>),
    receive
        {upgrade_result, Result} ->
            ?assertMatch({error, {http_status, 403, _}}, Result)
    after 2000 -> ct:fail(upgrade_not_answered)
    end,
    {ok, Next} = h1:request(Conn, <<"GET">>, <<"/next">>, []),
    Request = recv_until_headers(Srv),
    ?assertMatch(<<"GET /next HTTP/1.1\r\n", _/binary>>, Request),
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok">>),
    {Id, 403} = response_event(Conn),
    ?assertNotEqual(Next, Id),
    ?assertEqual(<<"forbidden">>, body_events(Conn, Id)),
    ?assertEqual({Next, 200}, response_event(Conn)),
    ?assertEqual(<<"ok">>, body_events(Conn, Next)),
    h1:close(Conn),
    gen_tcp:close(Srv).

%% An interim 1xx is not the answer to the upgrade: the caller keeps
%% waiting and returns on the final status.
client_upgrade_waits_past_interim(_Config) ->
    {Conn, Srv} = raw_client(),
    Test = self(),
    spawn_link(fun() ->
        Test ! {upgrade_result, h1:upgrade(Conn, <<"connect-udp">>, [])}
    end),
    _ = recv_until_headers(Srv),
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 103 Early Hints\r\n"
                             "link: </style.css>; rel=preload\r\n\r\n">>),
    ?assertMatch({informational, _, 103, _}, conn_event(Conn)),
    receive {upgrade_result, Early} -> ct:fail({returned_on_1xx, Early})
    after 300 -> ok
    end,
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 403 Forbidden\r\n"
                             "content-length: 0\r\n\r\n">>),
    receive
        {upgrade_result, Result} ->
            ?assertMatch({error, {http_status, 403, _}}, Result)
    after 2000 -> ct:fail(upgrade_not_answered)
    end,
    h1:close(Conn),
    gen_tcp:close(Srv).

%% End to end: an h1 server handler that answers an upgrade request with a
%% plain response refuses it, and the h1 client reports that status.
upgrade_refused_by_h1_server(Config0) ->
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        h1:respond(Conn, StreamId, 403, [], <<"forbidden">>)
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    ?assertMatch({error, {http_status, 403, _}},
                 h1:upgrade(Conn, <<"connect-udp">>,
                            [{<<"host">>, <<"localhost">>}], 5000)),
    {Id, 403} = response_event(Conn),
    ?assertEqual(<<"forbidden">>, body_events(Conn, Id)),
    h1:close(Conn).

%% The next `{response, ...}' event as `{StreamId, Status}'.
response_event(Conn) ->
    case conn_event(Conn) of
        {response, Id, Status, _Headers} -> {Id, Status};
        Other -> ct:fail({expected_response, Other})
    end.

%% The body of stream `Id', read from its data events up to the last one.
body_events(Conn, Id) ->
    body_events(Conn, Id, <<>>).
body_events(Conn, Id, Acc) ->
    case conn_event(Conn) of
        {data, Id, Data, false} -> body_events(Conn, Id, <<Acc/binary, Data/binary>>);
        {data, Id, Data, true} -> <<Acc/binary, Data/binary>>;
        Other -> ct:fail({expected_data, Id, Other})
    end.

%% An h1 client connected to a raw server socket held by the test.
raw_client() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                 {ip, {127,0,0,1}}]),
    {ok, Port} = inet:port(L),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Srv} = gen_tcp:accept(L, 5000),
    ok = gen_tcp:close(L),
    ok = h1:wait_connected(Conn),
    {Conn, Srv}.

%% The next response event for the connection, skipping `connected'.
conn_event(Conn) ->
    receive
        {h1, Conn, connected} -> conn_event(Conn);
        {h1, Conn, Event} -> Event
    after 5000 -> ct:fail(no_event)
    end.
