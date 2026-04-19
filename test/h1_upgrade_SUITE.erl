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
    upgrade_wire_path_in_request_line/1
]).

all() ->
    [upgrade_handshake, upgrade_capsule_exchange, upgrade_with_leftover_bytes,
     upgrade_with_path_pseudo_header, upgrade_wire_path_in_request_line].

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
        Ref -> catch h1:stop_server(Ref)
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
