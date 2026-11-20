%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc Pipelined requests are served one at a time: the next request is
%%% read only once the response to the one before has ended, as Cowboy does,
%%% so responses go out in request order (RFC 9112 §9.3.2). Raw `gen_tcp'
%%% clients, exact bytes.
-module(h1_pipeline_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).
-export([handoff_response_stays_in_order/1,
         read_ahead_in_separate_segment/1,
         connect_bytes_before_accept/1,
         pipelining_flood_is_bounded/1]).

-define(CHUNKED_HEAD, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n").

all() ->
    [handoff_response_stays_in_order, read_ahead_in_separate_segment,
     connect_bytes_before_accept, pipelining_flood_is_bounded].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Handler = fun(Conn, Id, Method, Path, _Hs) ->
                  tell({seen, Path, Conn}),
                  route(Method, Path, Conn, Id)
              end,
    {ok, Ref} = h1:start_server(0, #{transport => tcp, handler => Handler}),
    [{server, Ref}, {port, h1:server_port(Ref)} | Config].

end_per_suite(Config) ->
    h1:stop_server(?config(server, Config)).

init_per_testcase(_TC, Config) ->
    true = register(?MODULE, self()),
    Config.

end_per_testcase(_TC, _Config) ->
    unregister(?MODULE),
    ok.

%% ----------------------------------------------------------------------------
%% Handler routes
%% ----------------------------------------------------------------------------

route(<<"GET">>, <<"/handoff">>, C, Id) ->
    %% Return with the response unfinished: another process ends it.
    ok = h1:send_response(C, Id, 200, []),
    ok = h1:send_data(C, Id, <<"one">>, false),
    spawn(fun() ->
              timer:sleep(300),
              h1:send_data(C, Id, <<"two">>, true)
          end),
    ok;
route(<<"GET">>, <<"/block">>, C, Id) ->
    receive go -> ok after 10000 -> ok end,
    h1:respond(C, Id, 200, [], <<"done">>);
route(<<"CONNECT">>, _Authority, C, Id) ->
    %% A busy handler: the client's first tunnel bytes arrive meanwhile.
    timer:sleep(200),
    {ok, gen_tcp, Sock, Buffer} = h1:accept_connect(C, Id, []),
    tell({tunnel, Buffer}),
    ok = gen_tcp:send(Sock, <<"echo:", Buffer/binary>>),
    receive after 1000 -> ok end;
route(_Method, <<"/", Name/binary>>, C, Id) ->
    h1:respond(C, Id, 200, [], Name).

%% ----------------------------------------------------------------------------
%% Tests
%% ----------------------------------------------------------------------------

%% A handler returned before its response ended. The request pipelined
%% behind it is read only once that response has ended, so the two
%% responses cannot be written into each other.
handoff_response_stays_in_order(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [req(<<"/handoff">>), req(<<"/b">>)]),
    Expected = <<?CHUNKED_HEAD "3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n",
                 (resp(<<"b">>))/binary>>,
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    gen_tcp:close(Sock).

%% The same when the next request arrives in its own segment while the
%% first response is still being written.
read_ahead_in_separate_segment(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/handoff">>)),
    timer:sleep(100),
    ok = gen_tcp:send(Sock, req(<<"/b">>)),
    Expected = <<?CHUNKED_HEAD "3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n",
                 (resp(<<"b">>))/binary>>,
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    gen_tcp:close(Sock).

%% Bytes sent right after CONNECT belong to the tunnel (RFC 9110 §9.3.6).
%% They are held while the handler is busy, not parsed as HTTP, and handed
%% over with the socket.
connect_bytes_before_accept(Config) ->
    Sock = connect(Config),
    %% Tunnel bytes that look like lines, as many tunnelled protocols do.
    Tunnel = <<"hello\r\nworld\r\n\r\n">>,
    ok = gen_tcp:send(Sock, [<<"CONNECT example.com:443 HTTP/1.1\r\n"
                               "host: example.com:443\r\n\r\n">>,
                             Tunnel]),
    ?assertEqual(Tunnel, told(tunnel)),
    Expected = <<"HTTP/1.1 200 Connection Established\r\n\r\necho:",
                 Tunnel/binary>>,
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    gen_tcp:close(Sock).

%% A client pipelining far more than it waits for cannot make the server
%% read and queue it all: reading stops while a response is owed, and TCP
%% holds the rest back.
pipelining_flood_is_bounded(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/block">>)),
    Conn = seen(<<"/block">>),
    Handler = told(handler),
    Flood = binary:copy(iolist_to_binary(req(<<"/x">>)), 100000),
    Sender = spawn(fun() -> gen_tcp:send(Sock, Flood) end),
    timer:sleep(500),
    {links, Linked} = erlang:process_info(Conn, links),
    Procs = [Conn | [P || P <- Linked, is_pid(P)]],
    Memory = lists:sum([M || P <- Procs,
                             {memory, M} <- [erlang:process_info(P, memory)]]),
    Queued = lists:sum([Q || P <- Procs,
                             {message_queue_len, Q} <-
                                 [erlang:process_info(P, message_queue_len)]]),
    ct:pal("flood of ~p bytes: ~p bytes in ~p processes, ~p messages queued",
           [byte_size(Flood), Memory, length(Procs), Queued]),
    ?assert(Memory < 2 * 1024 * 1024),
    ?assert(Queued < 10),
    Handler ! go,
    exit(Sender, kill),
    gen_tcp:close(Sock).

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

tell(Msg) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Test ->
            case Msg of
                {seen, <<"/block">>, _} -> Test ! {handler, self()};
                _ -> ok
            end,
            Test ! Msg,
            ok
    end.

told(Tag) ->
    receive {Tag, Value} -> Value
    after 5000 -> ct:fail({nothing_told, Tag})
    end.

seen(Path) ->
    receive {seen, Path, Conn} -> Conn
    after 5000 -> ct:fail({no_handler, Path})
    end.

connect(Config) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", ?config(port, Config),
                                 [binary, {active, false}]),
    Sock.

req(Path) ->
    [<<"GET ">>, Path, <<" HTTP/1.1\r\nhost: x\r\n\r\n">>].

resp(Body) ->
    Len = integer_to_binary(byte_size(Body)),
    <<"HTTP/1.1 200 OK\r\ncontent-length: ", Len/binary, "\r\n\r\n", Body/binary>>.

recv_exact(Sock, N) ->
    case gen_tcp:recv(Sock, N, 5000) of
        {ok, Bin} -> Bin;
        {error, R} -> ct:fail({recv, R})
    end.
