%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc Receive-side flow control for request and response bodies.
%%%
%%% With `flow_control => manual' the server stops reading the socket once
%%% `recv_window' body bytes were handed to the handler and not given back
%%% with `h1:consume/3'. TCP then holds the client back. The early-response
%%% drain, a handler that exits and `request_timeout' are never stalled by
%%% the window. `auto' (the default) keeps reading as before.
%%%
%%% The client applies the same window to a response body when the request
%%% (or the connection) asks for `manual'.
%%%
%%% Server cases drive a raw gen_tcp client; client cases drive `h1:connect'
%%% against a raw gen_tcp server.
-module(h1_flow_control_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    manual_never_reads/1,
    manual_consume_content_length/1,
    manual_consume_chunked/1,
    consume_after_end/1,
    consume_auto_noop/1,
    auto_unchanged/1,
    manual_early_413/1,
    manual_handler_exit/1,
    manual_pipelined/1,
    manual_request_timeout/1,
    client_manual_never_reads/1,
    client_manual_consume_content_length/1,
    client_manual_consume_chunked/1,
    client_manual_close_delimited/1,
    client_consume_after_end/1,
    client_consume_auto_stream/1,
    client_connect_default/1,
    client_pipelined/1,
    client_handler_exit/1,
    client_request_timeout/1
]).

-define(MiB, (1024 * 1024)).
-define(WINDOW, 65536).

all() ->
    [manual_never_reads, manual_consume_content_length,
     manual_consume_chunked, consume_after_end, consume_auto_noop,
     auto_unchanged, manual_early_413, manual_handler_exit,
     manual_pipelined, manual_request_timeout,
     client_manual_never_reads, client_manual_consume_content_length,
     client_manual_consume_chunked, client_manual_close_delimited,
     client_consume_after_end, client_consume_auto_stream,
     client_connect_default, client_pipelined, client_handler_exit,
     client_request_timeout].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    Config.

%% Each case stops its own server; this catches the ones a failure skipped.
end_per_testcase(_TC, _Config) ->
    lists:foreach(fun({_, Pid, _, _}) when is_pid(Pid) ->
                          _ = supervisor:terminate_child(h1_sup, Pid);
                     (_) -> ok
                  end, supervisor:which_children(h1_sup)),
    ok.

%% ----------------------------------------------------------------------------
%% Cases
%% ----------------------------------------------------------------------------

%% A handler that never reads holds the body to the window plus one socket
%% read; the socket goes passive and nothing grows while the client sends.
manual_never_reads(_Config) ->
    {Ref, Port} = start(#{flow_control => manual}),
    S = connect(Port),
    Sender = send_async(S, [post_head(<<"/never">>, 10 * ?MiB),
                            body(10 * ?MiB)]),
    {Handler, Conn, _Id} = await_handler(),
    Sock = conn_socket(Conn),
    {ok, [{buffer, Buffer}]} = inet:getopts(Sock, [buffer]),
    ok = await_paused(Handler, Conn),
    Queued1 = queued_bytes(Handler, Conn),
    ct:pal("window ~p, buffer ~p, queued ~p", [?WINDOW, Buffer, Queued1]),
    ?assert(Queued1 >= ?WINDOW),
    ?assert(Queued1 =< ?WINDOW + Buffer),
    ?assertEqual({ok, [{active, false}]}, inet:getopts(Sock, [active])),
    timer:sleep(300),
    ?assertEqual(Queued1, queued_bytes(Handler, Conn)),
    ?assertEqual({ok, [{active, false}]}, inet:getopts(Sock, [active])),
    ?assertNot(sent(Sender, 0)),
    Handler ! stop,
    gen_tcp:close(S),
    h1:stop_server(Ref).

%% Consuming each chunk lets a 10 MiB content-length body through.
manual_consume_content_length(_Config) ->
    {_Ref, Port} = start(#{flow_control => manual}),
    S = connect(Port),
    Sender = send_async(S, [post_head(<<"/consume">>, 10 * ?MiB),
                            body(10 * ?MiB)]),
    {200, Body} = read_response(S),
    ?assertEqual(integer_to_binary(10 * ?MiB), Body),
    ?assert(sent(Sender, 5000)),
    gen_tcp:close(S).

%% Same with a chunked body: only payload bytes are counted.
manual_consume_chunked(_Config) ->
    {_Ref, Port} = start(#{flow_control => manual, recv_window => 16384}),
    S = connect(Port),
    Chunk = binary:copy(<<"c">>, 10000),
    N = 300,
    Wire = [<<"POST /consume HTTP/1.1\r\nhost: x\r\n"
              "transfer-encoding: chunked\r\n\r\n">>,
            [[integer_to_binary(byte_size(Chunk), 16), <<"\r\n">>, Chunk,
              <<"\r\n">>] || _ <- lists:seq(1, N)],
            <<"0\r\n\r\n">>],
    Sender = send_async(S, Wire),
    {200, Body} = read_response(S),
    ?assertEqual(integer_to_binary(N * byte_size(Chunk)), Body),
    ?assert(sent(Sender, 5000)),
    gen_tcp:close(S).

%% Once the body has ended, consume/3 reports the stream as unknown.
consume_after_end(_Config) ->
    {_Ref, Port} = start(#{flow_control => manual}),
    S = connect(Port),
    ok = gen_tcp:send(S, [post_head(<<"/consume">>, 1000), body(1000)]),
    {200, <<"1000">>} = read_response(S),
    receive
        {consumed, Results} ->
            {Before, [Last]} = lists:split(length(Results) - 1, Results),
            ?assert(lists:all(fun(R) -> R =:= ok end, Before)),
            ?assertEqual({error, unknown_stream}, Last)
    after 2000 -> ct:fail(no_consume_results)
    end,
    gen_tcp:close(S).

%% On an auto connection consume/3 is a no-op returning ok.
consume_auto_noop(_Config) ->
    {_Ref, Port} = start(#{}),
    S = connect(Port),
    ok = gen_tcp:send(S, [post_head(<<"/consume">>, 200000), body(200000)]),
    {200, <<"200000">>} = read_response(S),
    receive
        {consumed, Results} ->
            ?assert(lists:all(fun(R) -> R =:= ok end, Results))
    after 2000 -> ct:fail(no_consume_results)
    end,
    gen_tcp:close(S).

%% Default mode: a handler that never reads still gets the whole body
%% queued, as before this option existed.
auto_unchanged(_Config) ->
    {Ref, Port} = start(#{}),
    S = connect(Port),
    Size = ?MiB,
    Sender = send_async(S, [post_head(<<"/never">>, Size), body(Size)]),
    {Handler, Conn, _Id} = await_handler(),
    ?assert(sent(Sender, 5000)),
    ok = await(fun() -> queued_bytes(Handler, Conn) =:= Size end, 200),
    Handler ! stop,
    gen_tcp:close(S),
    h1:stop_server(Ref).

%% A handler that answers 413 without reading, with the window full, still
%% gets its response out; the connection drains and closes with a FIN.
manual_early_413(_Config) ->
    {_Ref, Port} = start(#{flow_control => manual}),
    S = connect(Port),
    Size = 10 * ?MiB,
    Sender = send_async(S, [post_head(<<"/early">>, Size), body(Size)]),
    {Handler, Conn, _Id} = await_handler(),
    ok = await_paused(Handler, Conn),
    MRef = monitor(process, Conn),
    Handler ! go,
    {413, <<"too large">>} = read_response(S),
    %% The drain reads the rest of the body, so the client's send completes.
    %% (Read the FIN only afterwards: a send blocked on a busy port fails
    %% once another process reads the close.)
    ?assert(sent(Sender, 10000)),
    %% Write side shut by the server: a clean end of stream, not a reset.
    ?assertEqual({error, closed}, gen_tcp:recv(S, 0, 5000)),
    gen_tcp:close(S),
    receive {'DOWN', MRef, process, Conn, _} -> ok
    after 5000 -> ct:fail(connection_not_closed)
    end.

%% A handler that ends mid-body releases the window: the rest of the body
%% is read and dropped, and closing the client frees every process.
manual_handler_exit(_Config) ->
    {_Ref, Port} = start(#{flow_control => manual}),
    S = connect(Port),
    Size = 10 * ?MiB,
    Sender = send_async(S, [post_head(<<"/exit">>, Size), body(Size)]),
    {Handler, Conn, _Id} = await_handler(),
    ok = await_paused(Handler, Conn),
    [Server] = [P || P <- element(2, process_info(Conn, links)), is_pid(P)],
    MConn = monitor(process, Conn),
    MServer = monitor(process, Server),
    Handler ! go,
    ?assert(sent(Sender, 10000)),
    Sock = conn_socket(Conn),
    ok = await(fun() ->
                   inet:getopts(Sock, [active]) =:= {ok, [{active, once}]}
               end, 200),
    gen_tcp:close(S),
    receive {'DOWN', MConn, process, Conn, _} -> ok
    after 5000 -> ct:fail(connection_not_closed)
    end,
    receive {'DOWN', MServer, process, Server, _} -> ok
    after 5000 -> ct:fail(server_loop_not_closed)
    end.

%% Two pipelined requests, each larger than the window, are both served in
%% order.
manual_pipelined(_Config) ->
    {_Ref, Port} = start(#{flow_control => manual, recv_window => 16384}),
    S = connect(Port),
    Size = 256 * 1024,
    Sender = send_async(S, [post_head(<<"/consume?a">>, Size), body(Size),
                            post_head(<<"/consume?b">>, Size), body(Size)]),
    Count = integer_to_binary(Size),
    ?assertEqual({200, <<"a:", Count/binary>>}, read_response(S)),
    ?assertEqual({200, <<"b:", Count/binary>>}, read_response(S)),
    ?assert(sent(Sender, 5000)),
    gen_tcp:close(S).

%% A paused request is still bounded by request_timeout.
manual_request_timeout(_Config) ->
    {_Ref, Port} = start(#{flow_control => manual, request_timeout => 500}),
    S = connect(Port),
    Size = 10 * ?MiB,
    _Sender = send_async(S, [post_head(<<"/never">>, Size), body(Size)]),
    {Handler, Conn, _Id} = await_handler(),
    MRef = monitor(process, Conn),
    receive
        {'DOWN', MRef, process, Conn, Reason} ->
            ?assertEqual({shutdown, request_timeout}, Reason)
    after 5000 -> ct:fail(no_request_timeout)
    end,
    Handler ! stop,
    gen_tcp:close(S).

%% ----------------------------------------------------------------------------
%% Client cases
%% ----------------------------------------------------------------------------

%% An owner that never reads a manual response holds it to the window plus
%% one socket read; the client socket goes passive and the server's send
%% stays blocked.
client_manual_never_reads(_Config) ->
    process_flag(trap_exit, true),
    Size = 10 * ?MiB,
    {Port, Server} = serve(fun(S) ->
                               recv_heads(S, 1),
                               report_sent(S, [resp_head(Size), body(Size)])
                           end),
    Conn = client(Port, #{}),
    {ok, _Id} = h1:request(Conn, get_req(<<"/">>), #{flow_control => manual}),
    Sock = conn_socket(Conn),
    {ok, [{buffer, Buffer}]} = inet:getopts(Sock, [buffer]),
    ok = await_client_paused(Conn),
    Queued = data_bytes(self()),
    ct:pal("window ~p, buffer ~p, queued ~p", [?WINDOW, Buffer, Queued]),
    ?assert(Queued =< ?WINDOW + Buffer),
    timer:sleep(300),
    ?assertEqual(Queued, data_bytes(self())),
    ?assertEqual({ok, [{active, false}]}, inet:getopts(Sock, [active])),
    ?assertNot(sent(Server, 0)),
    h1:close(Conn).

%% Consuming each chunk lets a 10 MiB content-length response through.
client_manual_consume_content_length(_Config) ->
    process_flag(trap_exit, true),
    Size = 10 * ?MiB,
    {Port, Server} = serve(fun(S) ->
                               recv_heads(S, 1),
                               report_sent(S, [resp_head(Size), body(Size)])
                           end),
    Conn = client(Port, #{}),
    {ok, Id} = h1:request(Conn, get_req(<<"/">>), #{flow_control => manual}),
    {Size, _} = client_read(Conn, Id),
    ?assert(sent(Server, 5000)),
    h1:close(Conn).

%% Same with a chunked response: only payload bytes are counted.
client_manual_consume_chunked(_Config) ->
    process_flag(trap_exit, true),
    Chunk = binary:copy(<<"c">>, 10000),
    N = 300,
    Wire = [<<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n">>,
            [[integer_to_binary(byte_size(Chunk), 16), <<"\r\n">>, Chunk,
              <<"\r\n">>] || _ <- lists:seq(1, N)],
            <<"0\r\n\r\n">>],
    {Port, Server} = serve(fun(S) -> recv_heads(S, 1), report_sent(S, Wire) end),
    Conn = client(Port, #{recv_window => 16384}),
    {ok, Id} = h1:request(Conn, get_req(<<"/">>), #{flow_control => manual}),
    Total = N * byte_size(Chunk),
    {Total, _} = client_read(Conn, Id),
    ?assert(sent(Server, 5000)),
    h1:close(Conn).

%% A close-delimited response ends when the server closes; the close is seen
%% once consuming resumes reading.
client_manual_close_delimited(_Config) ->
    process_flag(trap_exit, true),
    Size = 2 * ?MiB,
    {Port, Server} = serve(fun(S) ->
                               recv_heads(S, 1),
                               report_sent(S, [<<"HTTP/1.1 200 OK\r\n"
                                                 "connection: close\r\n\r\n">>,
                                               body(Size)]),
                               gen_tcp:close(S)
                           end),
    Conn = client(Port, #{}),
    {ok, Id} = h1:request(Conn, get_req(<<"/">>), #{flow_control => manual}),
    {Size, _} = client_read(Conn, Id),
    ?assert(sent(Server, 5000)).

%% Once the response body has ended, consume/3 reports the stream as unknown.
client_consume_after_end(_Config) ->
    process_flag(trap_exit, true),
    {Port, _Server} = serve(fun(S) ->
                                recv_heads(S, 1),
                                report_sent(S, [resp_head(1000), body(1000)]),
                                receive stop -> ok end
                            end),
    Conn = client(Port, #{}),
    {ok, Id} = h1:request(Conn, get_req(<<"/">>), #{flow_control => manual}),
    {1000, Results} = client_read(Conn, Id),
    ?assert(lists:all(fun(R) -> R =:= ok orelse R =:= {error, unknown_stream} end,
                      Results)),
    ?assertEqual({error, unknown_stream}, lists:last(Results)),
    ?assertEqual({error, unknown_stream}, h1:consume(Conn, Id, 10)),
    h1:close(Conn).

%% consume/3 on an auto stream is a no-op returning ok while the body runs;
%% an owner that never consumes still gets the whole body.
client_consume_auto_stream(_Config) ->
    process_flag(trap_exit, true),
    Size = ?MiB,
    {Port, Server} = serve(fun(S) ->
                               recv_heads(S, 1),
                               report_sent(S, [resp_head(Size), body(Size)]),
                               receive stop -> ok end
                           end),
    Conn = client(Port, #{}),
    {ok, Id} = h1:request(Conn, get_req(<<"/">>), #{}),
    ?assertEqual(ok, h1:consume(Conn, Id, 10)),
    ?assert(sent(Server, 5000)),
    ok = await(fun() -> data_bytes(self()) =:= Size end, 200),
    h1:close(Conn).

%% flow_control on connect/3 is the default for every request; a request
%% can still ask for auto.
client_connect_default(_Config) ->
    process_flag(trap_exit, true),
    Size = 10 * ?MiB,
    Wire = [resp_head(Size), body(Size)],
    {Port1, Server1} = serve(fun(S) -> recv_heads(S, 1), report_sent(S, Wire) end),
    Conn1 = client(Port1, #{flow_control => manual}),
    {ok, _} = h1:request(Conn1, <<"GET">>, <<"/">>, [{<<"host">>, <<"x">>}]),
    ok = await_client_paused(Conn1),
    ?assertNot(sent(Server1, 300)),
    h1:close(Conn1),
    flush_data(),
    Small = ?MiB,
    {Port2, Server2} = serve(fun(S) ->
                                 recv_heads(S, 1),
                                 report_sent(S, [resp_head(Small), body(Small)]),
                                 receive stop -> ok end
                             end),
    Conn2 = client(Port2, #{flow_control => manual}),
    {ok, _} = h1:request(Conn2, get_req(<<"/">>), #{flow_control => auto}),
    ?assert(sent(Server2, 5000)),
    ok = await(fun() -> data_bytes(self()) =:= Small end, 200),
    h1:close(Conn2).

%% Two pipelined manual requests: both responses are read, in order.
client_pipelined(_Config) ->
    process_flag(trap_exit, true),
    A = 200000,
    B = 300000,
    {Port, Server} = serve(fun(S) ->
                               recv_heads(S, 2),
                               report_sent(S, [resp_head(A), body(A),
                                               resp_head(B), body(B)])
                           end),
    Conn = client(Port, #{recv_window => 16384}),
    {ok, Id1} = h1:request(Conn, get_req(<<"/a">>), #{flow_control => manual}),
    {ok, Id2} = h1:request(Conn, get_req(<<"/b">>), #{flow_control => manual}),
    {A, _} = client_read(Conn, Id1),
    {B, _} = client_read(Conn, Id2),
    ?assert(sent(Server, 5000)),
    h1:close(Conn).

%% A handler that exits while its manual response is paused releases the
%% window: the rest is read and dropped, and the connection keeps working.
client_handler_exit(_Config) ->
    process_flag(trap_exit, true),
    Size = 10 * ?MiB,
    {Port, Server} = serve(fun(S) ->
                               recv_heads(S, 1),
                               report_sent(S, [resp_head(Size), body(Size)]),
                               recv_heads(S, 1),
                               ok = gen_tcp:send(S, [resp_head(2), <<"ok">>]),
                               receive stop -> ok end
                           end),
    Conn = client(Port, #{}),
    {ok, Id} = h1:request(Conn, get_req(<<"/">>), #{flow_control => manual}),
    Handler = spawn(fun() -> receive go -> ok end end),
    {ok, _} = h1:set_stream_handler(Conn, Id, Handler),
    Sock = conn_socket(Conn),
    ok = await(fun() ->
                   data_bytes(Handler) >= ?WINDOW andalso
                       inet:getopts(Sock, [active]) =:= {ok, [{active, false}]}
               end, 200),
    Handler ! go,
    ?assert(sent(Server, 10000)),
    {ok, Id2} = h1:request(Conn, get_req(<<"/next">>), #{}),
    {2, _} = client_read(Conn, Id2),
    h1:close(Conn).

%% A paused response is still bounded by request_timeout.
client_request_timeout(_Config) ->
    process_flag(trap_exit, true),
    Size = 10 * ?MiB,
    {Port, _Server} = serve(fun(S) ->
                                recv_heads(S, 1),
                                report_sent(S, [resp_head(Size), body(Size)])
                            end),
    Conn = client(Port, #{request_timeout => 500}),
    MRef = monitor(process, Conn),
    {ok, _} = h1:request(Conn, get_req(<<"/">>), #{flow_control => manual}),
    receive
        {'DOWN', MRef, process, Conn, Reason} ->
            ?assertEqual({shutdown, request_timeout}, Reason)
    after 5000 -> ct:fail(no_request_timeout)
    end.

%% ----------------------------------------------------------------------------
%% Server and handlers
%% ----------------------------------------------------------------------------

start(Opts) ->
    Test = self(),
    Handler = fun(Conn, Id, _Method, Path, _Hs) ->
                  Test ! {handler, self(), Conn, Id},
                  route(Path, Conn, Id, Test)
              end,
    %% The 10 MiB bodies are over the default max_body_size (8 MiB).
    {ok, Ref} = h1:start_server(0, maps:merge(#{max_body_size => 64 * ?MiB},
                                              Opts#{transport => tcp,
                                                    handler => Handler,
                                                    acceptors => 1})),
    {Ref, h1:server_port(Ref)}.

route(<<"/never">>, _C, _Id, _Test) ->
    %% Never touch the body messages: only wait to be told to stop.
    receive stop -> ok end;
route(<<"/early">>, C, Id, _Test) ->
    receive go -> ok end,
    h1:respond(C, Id, 413, [], <<"too large">>);
route(<<"/exit">>, _C, _Id, _Test) ->
    receive go -> ok end;
route(<<"/consume?", Tag/binary>>, C, Id, Test) ->
    consume_loop(C, Id, Test, <<Tag/binary, ":">>, 0, []);
route(<<"/consume">>, C, Id, Test) ->
    consume_loop(C, Id, Test, <<>>, 0, []).

%% Read the body, giving back credit for each chunk, then answer with the
%% byte count (prefixed with the query tag, if any).
consume_loop(C, Id, Test, Tag, Count, Results) ->
    receive
        {h1_stream, Id, {data, Data, Fin}} ->
            R = h1:consume(C, Id, byte_size(Data)),
            Count1 = Count + byte_size(Data),
            case Fin of
                true ->
                    Test ! {consumed, lists:reverse([R | Results])},
                    h1:respond(C, Id, 200, [],
                               <<Tag/binary, (integer_to_binary(Count1))/binary>>);
                false ->
                    consume_loop(C, Id, Test, Tag, Count1, [R | Results])
            end;
        {h1_stream, Id, {trailers, _}} ->
            consume_loop(C, Id, Test, Tag, Count, Results)
    after 10000 ->
        exit(body_timeout)
    end.

%% ----------------------------------------------------------------------------
%% Client helpers
%% ----------------------------------------------------------------------------

connect(Port) ->
    {ok, S} = gen_tcp:connect({127, 0, 0, 1}, Port,
                              [binary, {active, false}, {packet, raw}]),
    S.

post_head(Path, Size) ->
    [<<"POST ">>, Path, <<" HTTP/1.1\r\nhost: x\r\ncontent-length: ">>,
     integer_to_binary(Size), <<"\r\n\r\n">>].

body(Size) ->
    binary:copy(<<"b">>, Size).

%% Send from another process so the test can watch the server while the
%% client is blocked on a full socket. One large send returns once the port
%% queues it, so write in pieces: each blocks while the port is busy.
send_async(S, Wire) ->
    Test = self(),
    Bin = iolist_to_binary(Wire),
    spawn(fun() -> Test ! {sent, self(), send_pieces(S, Bin)} end).

send_pieces(S, Bin) when byte_size(Bin) > 65536 ->
    <<Piece:65536/binary, Rest/binary>> = Bin,
    case gen_tcp:send(S, Piece) of
        ok -> send_pieces(S, Rest);
        Error -> Error
    end;
send_pieces(S, Bin) ->
    gen_tcp:send(S, Bin).

sent(Sender, Timeout) ->
    receive {sent, Sender, ok} -> true
    after Timeout -> false
    end.

%% Read one content-length response: {Status, Body}.
read_response(S) ->
    read_response(S, get_buf()).

read_response(S, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [Head, Rest] ->
            [StatusLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
            [_, Code | _] = binary:split(StatusLine, <<" ">>, [global]),
            Len = content_length(Lines),
            Body = read_exact(S, Rest, Len),
            {binary_to_integer(Code), Body};
        [_] ->
            {ok, More} = gen_tcp:recv(S, 0, 10000),
            read_response(S, <<Buf/binary, More/binary>>)
    end.

read_exact(_S, Buf, Len) when byte_size(Buf) >= Len ->
    <<Body:Len/binary, Rest/binary>> = Buf,
    put(buf, Rest),
    Body;
read_exact(S, Buf, Len) ->
    {ok, More} = gen_tcp:recv(S, 0, 10000),
    read_exact(S, <<Buf/binary, More/binary>>, Len).

get_buf() ->
    case erase(buf) of
        undefined -> <<>>;
        B -> B
    end.

content_length([]) -> 0;
content_length([Line | Rest]) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            case string:lowercase(Name) of
                <<"content-length">> ->
                    binary_to_integer(string:trim(Value));
                _ -> content_length(Rest)
            end;
        _ -> content_length(Rest)
    end.

%% ----------------------------------------------------------------------------
%% Client-case helpers: a raw server and the h1 client
%% ----------------------------------------------------------------------------

%% Accept one connection and run `Fun' on it in its own process. `Fun'
%% reports its writes with report_sent/2, read by sent/2.
serve(Fun) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {packet, raw},
                                 {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    Test = self(),
    Pid = spawn(fun() ->
                    {ok, S} = gen_tcp:accept(L, 5000),
                    put(test, Test),
                    Fun(S),
                    gen_tcp:close(L)
                end),
    {Port, Pid}.

report_sent(S, Wire) ->
    erlang:get(test) ! {sent, self(), send_pieces(S, iolist_to_binary(Wire))}.

%% Read until `N' request heads were received.
recv_heads(S, N) ->
    recv_heads(S, N, <<>>).

recv_heads(_S, 0, _Buf) ->
    ok;
recv_heads(S, N, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [_, Rest] -> recv_heads(S, N - 1, Rest);
        [_] ->
            {ok, More} = gen_tcp:recv(S, 0, 5000),
            recv_heads(S, N, <<Buf/binary, More/binary>>)
    end.

resp_head(Size) ->
    [<<"HTTP/1.1 200 OK\r\ncontent-length: ">>, integer_to_binary(Size),
     <<"\r\n\r\n">>].

client(Port, Opts) ->
    {ok, Conn} = h1:connect("127.0.0.1", Port,
                            maps:merge(#{max_body_size => infinity}, Opts)),
    Conn.

get_req(Path) ->
    [{<<":method">>, <<"GET">>}, {<<":path">>, Path}, {<<"host">>, <<"x">>}].

%% Read the response body of `Id', consuming each chunk. Returns the byte
%% count and the consume/3 results in order.
client_read(Conn, Id) ->
    client_read(Conn, Id, 0, []).

client_read(Conn, Id, Count, Results) ->
    receive
        {h1, Conn, {response, Id, _Status, _Hs}} ->
            client_read(Conn, Id, Count, Results);
        {h1, Conn, {data, Id, Data, Fin}} ->
            R = h1:consume(Conn, Id, byte_size(Data)),
            Count1 = Count + byte_size(Data),
            case Fin of
                true -> {Count1, lists:reverse([R | Results])};
                false -> client_read(Conn, Id, Count1, [R | Results])
            end
    after 10000 ->
        ct:fail({body_timeout, Id, Count})
    end.

await_client_paused(Conn) ->
    Sock = conn_socket(Conn),
    await(fun() ->
              data_bytes(self()) >= ?WINDOW andalso
                  inet:getopts(Sock, [active]) =:= {ok, [{active, false}]}
          end, 200).

flush_data() ->
    receive {h1, _, _} -> flush_data()
    after 0 -> ok
    end.

%% ----------------------------------------------------------------------------
%% Server-side observation (internal state, not public API)
%% ----------------------------------------------------------------------------

await_handler() ->
    receive {handler, Pid, Conn, Id} -> {Pid, Conn, Id}
    after 5000 -> ct:fail(no_handler)
    end.

%% Paused: the window is full and the socket is passive. A passive socket
%% alone can be the moment between a delivery and the next re-arm.
await_paused(Handler, Conn) ->
    Sock = conn_socket(Conn),
    await(fun() ->
              queued_bytes(Handler, Conn) >= ?WINDOW andalso
                  inet:getopts(Sock, [active]) =:= {ok, [{active, false}]}
          end, 200).

await(_Pred, 0) ->
    {error, timeout};
await(Pred, N) ->
    case Pred() of
        true -> ok;
        false -> timer:sleep(25), await(Pred, N - 1)
    end.

%% Body bytes delivered to the handler or the h1_server loop and not read.
queued_bytes(Handler, Conn) ->
    Server = [P || P <- element(2, process_info(Conn, links)), is_pid(P)],
    lists:sum([data_bytes(P) || P <- [Handler | Server]]).

data_bytes(Pid) ->
    case process_info(Pid, messages) of
        {messages, Msgs} ->
            lists:sum([byte_size(D) || M <- Msgs, D <- data_of(M)]);
        undefined -> 0
    end.

data_of({h1_stream, _, {data, D, _}}) -> [D];
data_of({h1, _, {data, _, D, _}}) -> [D];
data_of(_) -> [].

conn_socket(Conn) ->
    {_StateName, State} = sys:get_state(Conn),
    {value, Sock} = lists:search(fun erlang:is_port/1, tuple_to_list(State)),
    Sock.
