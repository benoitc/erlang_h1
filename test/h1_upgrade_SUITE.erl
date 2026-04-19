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
    upgrade_with_leftover_bytes/1
]).

all() ->
    [upgrade_handshake, upgrade_capsule_exchange, upgrade_with_leftover_bytes].

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

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

start_server(Handler, Config) ->
    Opts = #{transport => tcp, handler => Handler, acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    [{server_ref, Ref} | Config].
