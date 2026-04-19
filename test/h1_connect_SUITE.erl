%%% @doc End-to-end tests for `h1:accept_connect/3,4': classic HTTP/1.1
%%% CONNECT with 200 Connection Established and raw socket handoff
%%% (RFC 9110 §9.3.6, RFC 9112 §3.2.3).
-module(h1_connect_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    accept_connect_happy_path/1,
    accept_connect_authority_ipv6/1,
    accept_connect_extra_headers/1,
    accept_connect_response_already_sent/1,
    accept_connect_unknown_stream/1,
    accept_connect_no_chunked_framing/1,
    accept_connect_socket_not_closed/1,
    accept_connect_shutdown_reason/1
]).

all() ->
    [accept_connect_happy_path,
     accept_connect_authority_ipv6,
     accept_connect_extra_headers,
     accept_connect_response_already_sent,
     accept_connect_unknown_stream,
     accept_connect_no_chunked_framing,
     accept_connect_socket_not_closed,
     accept_connect_shutdown_reason].

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
%% Tests
%% ----------------------------------------------------------------------------

accept_connect_happy_path(Config0) ->
    Parent = self(),
    Handler = fun(Conn, StreamId, Method, Path, _Hs) ->
        Parent ! {method_path, Method, Path},
        case h1:accept_connect(Conn, StreamId, []) of
            {ok, Transport, Sock, Buf} ->
                Parent ! {server_connected, Transport, Sock, Buf},
                %% Echo tunnel bytes back until the client closes.
                ok = inet:setopts(Sock, [{active, false}]),
                echo_loop(Sock);
            {error, R} ->
                Parent ! {server_error, R}
        end
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port,
                                    [binary, {active, false}, {packet, raw}]),
    Req = <<"CONNECT example.com:443 HTTP/1.1\r\n"
            "Host: example.com:443\r\n\r\n">>,
    ok = gen_tcp:send(Client, Req),
    Resp = recv_until_headers(Client),
    ?assertMatch(<<"HTTP/1.1 200 Connection Established\r\n", _/binary>>, Resp),
    receive {method_path, <<"CONNECT">>, <<"example.com:443">>} -> ok
    after 2000 -> ct:fail(no_request_event)
    end,
    receive {server_connected, gen_tcp, _, <<>>} -> ok
    after 2000 -> ct:fail(no_server_connected)
    end,
    ok = gen_tcp:send(Client, <<"ping">>),
    {ok, <<"ping">>} = gen_tcp:recv(Client, 4, 2000),
    ok = gen_tcp:send(Client, <<"pong">>),
    {ok, <<"pong">>} = gen_tcp:recv(Client, 4, 2000),
    ok = gen_tcp:close(Client),
    ok.

accept_connect_authority_ipv6(Config0) ->
    Parent = self(),
    Handler = fun(Conn, StreamId, Method, Path, _Hs) ->
        Parent ! {method_path, Method, Path},
        {ok, _T, Sock, _Buf} = h1:accept_connect(Conn, StreamId, []),
        ok = inet:setopts(Sock, [{active, false}]),
        _ = gen_tcp:recv(Sock, 0, 500),
        gen_tcp:close(Sock)
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port,
                                    [binary, {active, false}, {packet, raw}]),
    Req = <<"CONNECT [::1]:443 HTTP/1.1\r\n"
            "Host: [::1]:443\r\n\r\n">>,
    ok = gen_tcp:send(Client, Req),
    receive {method_path, <<"CONNECT">>, <<"[::1]:443">>} -> ok
    after 2000 -> ct:fail(ipv6_authority_not_received)
    end,
    _ = gen_tcp:close(Client),
    ok.

accept_connect_extra_headers(Config0) ->
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        {ok, _T, Sock, _Buf} = h1:accept_connect(Conn, StreamId,
            [{<<"proxy-authenticate">>, <<"Basic">>}]),
        ok = inet:setopts(Sock, [{active, false}]),
        _ = gen_tcp:recv(Sock, 0, 500),
        gen_tcp:close(Sock)
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port,
                                    [binary, {active, false}, {packet, raw}]),
    Req = <<"CONNECT host:443 HTTP/1.1\r\nHost: host:443\r\n\r\n">>,
    ok = gen_tcp:send(Client, Req),
    Resp = recv_until_headers(Client),
    ?assertMatch(<<"HTTP/1.1 200 Connection Established\r\n", _/binary>>, Resp),
    %% Case-insensitive match on the extra header we passed.
    Lower = string:lowercase(Resp),
    ?assert(binary:match(Lower,
                         <<"proxy-authenticate: basic">>) =/= nomatch),
    _ = gen_tcp:close(Client),
    ok.

accept_connect_response_already_sent(Config0) ->
    Parent = self(),
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        ok = h1:send_response(Conn, StreamId, 200,
                              [{<<"content-length">>, <<"0">>}]),
        R = h1:accept_connect(Conn, StreamId, []),
        Parent ! {accept_connect_result, R}
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port,
                                    [binary, {active, false}, {packet, raw}]),
    Req = <<"CONNECT host:443 HTTP/1.1\r\nHost: host:443\r\n\r\n">>,
    ok = gen_tcp:send(Client, Req),
    receive {accept_connect_result, Res} ->
        ?assertEqual({error, response_already_sent}, Res)
    after 2000 -> ct:fail(no_result)
    end,
    _ = gen_tcp:close(Client),
    ok.

accept_connect_unknown_stream(Config0) ->
    Parent = self(),
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        R = h1:accept_connect(Conn, 99999, []),
        Parent ! {accept_connect_result, R},
        ok = h1:send_response(Conn, StreamId, 200,
                              [{<<"content-length">>, <<"0">>}]),
        ok = h1:send_data(Conn, StreamId, <<>>, true)
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port,
                                    [binary, {active, false}, {packet, raw}]),
    Req = <<"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
    ok = gen_tcp:send(Client, Req),
    receive {accept_connect_result, Res} ->
        ?assertEqual({error, unknown_stream}, Res)
    after 2000 -> ct:fail(no_result)
    end,
    _ = gen_tcp:close(Client),
    ok.

accept_connect_no_chunked_framing(Config0) ->
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        {ok, _T, Sock, _Buf} = h1:accept_connect(Conn, StreamId, []),
        ok = inet:setopts(Sock, [{active, false}]),
        _ = gen_tcp:recv(Sock, 0, 500),
        gen_tcp:close(Sock)
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port,
                                    [binary, {active, false}, {packet, raw}]),
    Req = <<"CONNECT host:443 HTTP/1.1\r\nHost: host:443\r\n\r\n">>,
    ok = gen_tcp:send(Client, Req),
    Resp = recv_until_headers(Client),
    Lower = string:lowercase(Resp),
    ?assertEqual(nomatch,
                 binary:match(Lower, <<"transfer-encoding">>)),
    ?assertEqual(nomatch,
                 binary:match(Lower, <<"chunked">>)),
    _ = gen_tcp:close(Client),
    ok.

accept_connect_socket_not_closed(Config0) ->
    Parent = self(),
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        {ok, Transport, Sock, Buf} = h1:accept_connect(Conn, StreamId, []),
        %% Hand the socket to the test process so we can probe
        %% controlling_process/2 from outside.
        ok = gen_tcp:controlling_process(Sock, Parent),
        Parent ! {handoff, Transport, Sock, Buf},
        receive done -> ok after 2000 -> ok end
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port,
                                    [binary, {active, false}, {packet, raw}]),
    Req = <<"CONNECT host:443 HTTP/1.1\r\nHost: host:443\r\n\r\n">>,
    ok = gen_tcp:send(Client, Req),
    receive {handoff, gen_tcp, Sock, <<>>} ->
        %% Probe: we are now the controlling process. Transferring back
        %% should succeed, which proves the socket is still open and owned
        %% by us (i.e. the connection's terminate/3 did not close it).
        Self = self(),
        Probe = spawn(fun() ->
            receive sock -> ok end,
            Self ! probed
        end),
        ok = gen_tcp:controlling_process(Sock, Probe),
        Probe ! sock,
        receive probed -> ok after 1000 -> ct:fail(no_probe) end,
        ok = gen_tcp:close(Sock)
    after 2000 -> ct:fail(no_handoff)
    end,
    _ = gen_tcp:close(Client),
    ok.

accept_connect_shutdown_reason(Config0) ->
    Parent = self(),
    Handler = fun(Conn, StreamId, _M, _P, _Hs) ->
        Ref = erlang:monitor(process, Conn),
        {ok, _T, Sock, _Buf} = h1:accept_connect(Conn, StreamId, []),
        receive
            {'DOWN', Ref, process, Conn, Reason} ->
                Parent ! {down_reason, Reason}
        after 2000 -> Parent ! {down_reason, timeout}
        end,
        gen_tcp:close(Sock)
    end,
    Config = start_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port,
                                    [binary, {active, false}, {packet, raw}]),
    Req = <<"CONNECT host:443 HTTP/1.1\r\nHost: host:443\r\n\r\n">>,
    ok = gen_tcp:send(Client, Req),
    receive {down_reason, Reason} ->
        ?assertEqual({shutdown, connected}, Reason)
    after 3000 -> ct:fail(no_down)
    end,
    _ = gen_tcp:close(Client),
    ok.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

start_server(Handler, Config) ->
    Opts = #{transport => tcp, handler => Handler, acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    [{server_ref, Ref} | Config].

echo_loop(Sock) ->
    case gen_tcp:recv(Sock, 0, 2000) of
        {ok, Data} ->
            ok = gen_tcp:send(Sock, Data),
            echo_loop(Sock);
        {error, _} ->
            gen_tcp:close(Sock)
    end.

%% Read bytes until we have seen CRLFCRLF (end of response headers).
recv_until_headers(Sock) ->
    recv_until_headers(Sock, <<>>).

recv_until_headers(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 2000) of
                {ok, Bin} -> recv_until_headers(Sock, <<Acc/binary, Bin/binary>>);
                {error, R} -> ct:fail({recv_until_headers, R, Acc})
            end;
        _ -> Acc
    end.
