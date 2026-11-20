%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc Cancelling a stream, on the server and on the client.
%%%
%%% HTTP/1.1 has no stream reset: a server that will not finish a response
%%% can only say so by closing the connection, and the client then records
%%% the message as incomplete (RFC 9112 §8; §6.3 item 6 for a
%%% Content-Length body cut short). `h1:cancel/2,3' on a stream whose
%%% response has not ended therefore closes the connection, whether or not
%%% a response byte went out. A response that ends normally keeps the
%%% connection alive, and a client that leaves is still reported to the
%%% handler. A client that cancels a request closes the connection as well,
%%% once the responses to earlier pipelined requests have been read.
%%%
%%% Each case drives a raw gen_tcp client and asserts the exact bytes.
-module(h1_cancel_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    cancel_chunked_response/1,
    cancel_content_length_response/1,
    cancel_before_response/1,
    cancel_after_interim_response/1,
    cancel_sends_write_nothing/1,
    cancel_later_pipelined_stream/1,
    cancel_finished_stream/1,
    complete_response_keeps_alive/1,
    client_disconnect_reported/1,
    second_final_response_refused/1,
    interim_then_final_response/1,
    client_cancel_before_response/1,
    client_cancel_mid_response/1,
    client_cancel_mid_upload/1,
    client_cancel_pipelined/1,
    client_cancel_finished_stream/1,
    cancel_first_pipelined_stream/1,
    cancel_during_upload/1,
    second_response_after_end/1,
    crash_after_partial_response/1,
    crash_before_response/1,
    crash_after_response/1,
    client_cancel_two_pipelined/1,
    client_cancel_two_pipelined_reversed/1,
    client_upgrade_while_closing/1
]).

all() ->
    [cancel_chunked_response, cancel_content_length_response,
     cancel_before_response, cancel_after_interim_response,
     cancel_sends_write_nothing, cancel_later_pipelined_stream,
     cancel_finished_stream, complete_response_keeps_alive,
     client_disconnect_reported,
     second_final_response_refused, interim_then_final_response,
     client_cancel_before_response, client_cancel_mid_response,
     client_cancel_mid_upload, client_cancel_pipelined,
     client_cancel_finished_stream,
     cancel_first_pipelined_stream, cancel_during_upload,
     second_response_after_end,
     crash_after_partial_response, crash_before_response,
     crash_after_response,
     client_cancel_two_pipelined, client_cancel_two_pipelined_reversed,
     client_upgrade_while_closing].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Handler = fun(Conn, Id, _Method, Path, _Hs) ->
                  tell({seen, Path, Conn}),
                  route(Path, Conn, Id)
              end,
    {ok, Ref} = h1:start_server(0, #{transport => tcp, handler => Handler,
                                    acceptors => 2}),
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

route(<<"/chunked">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, [{<<"content-type">>, <<"text/plain">>}]),
    ok = h1:send_data(C, Id, <<"one">>, false),
    %% Let the test monitor the connection before it stops.
    wait_go(),
    tell({cancel, h1:cancel_stream(C, Id, test)}),
    tell({event, next_event(Id)});
route(<<"/length">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, [{<<"content-length">>, <<"10">>}]),
    ok = h1:send_data(C, Id, <<"one">>, false),
    tell({cancel, h1:cancel(C, Id)});
route(<<"/none">>, C, Id) ->
    tell({cancel, h1:cancel(C, Id)});
route(<<"/interim">>, C, Id) ->
    ok = h1:send_informational(C, Id, 103, [{<<"link">>, <<"</a>">>}]),
    tell({cancel, h1:cancel(C, Id)});
route(<<"/sends">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, []),
    ok = h1:send_data(C, Id, <<"one">>, false),
    ok = h1:cancel(C, Id),
    tell({sends, [attempt(fun() -> h1:send_response(C, Id, 200, []) end),
                  attempt(fun() -> h1:send_data(C, Id, <<"two">>, false) end),
                  attempt(fun() -> h1:send_data(C, Id, <<"end">>, true) end),
                  attempt(fun() -> h1:send_trailers(C, Id, [{<<"x-t">>, <<"1">>}]) end),
                  attempt(fun() -> h1:respond(C, Id, 200, [], <<"again">>) end)]});
route(<<"/first">>, C, Id) ->
    %% Let the pipelined request behind this one be read.
    timer:sleep(200),
    ok = h1:send_response(C, Id, 200, []),
    ok = h1:send_data(C, Id, <<"one">>, false),
    ok = h1:cancel(C, Id + 1),
    tell({later, attempt(fun() -> h1:respond(C, Id + 1, 200, [], <<"no">>) end)}),
    ok = h1:send_data(C, Id, <<"two">>, true);
route(<<"/second">>, C, Id) ->
    attempt(fun() -> h1:respond(C, Id, 200, [], <<"second">>) end);
route(<<"/done">>, C, Id) ->
    ok = h1:respond(C, Id, 200, [], <<"done">>),
    tell({cancel, h1:cancel(C, Id)});
route(<<"/wait">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, []),
    ok = h1:send_data(C, Id, <<"one">>, false),
    tell({event, next_event(Id)});
route(<<"/twice">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, [{<<"content-length">>, <<"2">>}]),
    tell({twice, [h1:send_response(C, Id, 500, []),
                  h1:respond(C, Id, 500, [], <<"no">>)]}),
    ok = h1:send_data(C, Id, <<"ok">>, true);
route(<<"/hints">>, C, Id) ->
    ok = h1:send_response(C, Id, 103, [{<<"link">>, <<"</a>">>}]),
    ok = h1:send_response(C, Id, 200, [{<<"content-length">>, <<"2">>}]),
    ok = h1:send_data(C, Id, <<"ok">>, true);
route(<<"/cut">>, C, Id) ->
    %% Let the pipelined request behind this one be read, then cancel this
    %% one: no earlier response is owed, so the connection closes.
    timer:sleep(200),
    ok = h1:send_response(C, Id, 200, []),
    ok = h1:send_data(C, Id, <<"one">>, false),
    tell({cancel, h1:cancel(C, Id)});
route(<<"/upload">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, []),
    ok = h1:send_data(C, Id, <<"one">>, false),
    wait_go(),
    tell({cancel, h1:cancel(C, Id)});
route(<<"/again">>, C, Id) ->
    ok = h1:respond(C, Id, 200, [], <<"x">>),
    tell({again, h1:respond(C, Id, 200, [], <<"y">>)});
route(<<"/crash-partial">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, []),
    ok = h1:send_data(C, Id, <<"one">>, false),
    error(boom);
route(<<"/crash">>, _C, _Id) ->
    error(boom);
route(<<"/crash-done">>, C, Id) ->
    ok = h1:respond(C, Id, 200, [], <<"done">>),
    error(boom);
route(<<"/", Name/binary>>, C, Id) ->
    h1:respond(C, Id, 200, [], Name).

wait_go() ->
    tell({ready, self()}),
    receive go -> ok after 5000 -> ok end.

go() ->
    told(ready) ! go,
    ok.

tell(Msg) ->
    case whereis(?MODULE) of
        undefined -> ok;
        Test -> Test ! Msg, ok
    end.

%% The value of a call, or `{'EXIT', Reason}' when it exits.
attempt(Fun) ->
    try Fun()
    catch exit:Reason -> {'EXIT', Reason}
    end.

%% The next event for the stream that is not request body.
next_event(Id) ->
    receive
        {h1_stream, Id, {data, _, _}} -> next_event(Id);
        {h1_stream, Id, Event} -> Event
    after 5000 -> timeout
    end.

%% ----------------------------------------------------------------------------
%% Cancel closes the connection
%% ----------------------------------------------------------------------------

-define(CHUNKED_HEAD, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n").

%% Head and one chunk, then cancel: the client reads both and then end of
%% file. No zero-size chunk is written, so the response is incomplete
%% (RFC 9112 §8). The handler is told as before, and the connection process
%% stops with a shutdown reason.
cancel_chunked_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/chunked">>)),
    Conn = seen(<<"/chunked">>),
    MRef = erlang:monitor(process, Conn),
    ok = go(),
    ?assertEqual({closed, <<"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n"
                            "transfer-encoding: chunked\r\n\r\n"
                            "3\r\none\r\n">>},
                 recv_all(Sock)),
    ?assertEqual(ok, told(cancel)),
    ?assertEqual({stream_reset, cancel}, told(event)),
    receive {'DOWN', MRef, process, Conn, Reason} ->
        ?assertEqual({shutdown, stream_cancelled}, Reason)
    after 5000 -> ct:fail(connection_still_alive)
    end.

%% A Content-Length response cut short: the client reads fewer bytes than
%% announced and then end of file (RFC 9112 §6.3 item 6).
cancel_content_length_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/length">>)),
    ?assertEqual({closed, <<"HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\n"
                            "one">>},
                 recv_all(Sock)),
    ?assertEqual(ok, told(cancel)).

%% A cancel before any response byte: the client would wait for a response
%% that never comes, so the connection closes with nothing written.
cancel_before_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/none">>)),
    ?assertEqual({closed, <<>>}, recv_all(Sock)),
    ?assertEqual(ok, told(cancel)).

%% An interim response is not the final one: same close.
cancel_after_interim_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/interim">>)),
    ?assertEqual({closed, <<"HTTP/1.1 103 Early Hints\r\nlink: </a>\r\n\r\n">>},
                 recv_all(Sock)),
    ?assertEqual(ok, told(cancel)).

%% Nothing can be sent on a cancelled stream: the connection is gone, so the
%% send calls exit as they do after any other close, and no byte follows the
%% chunk that was sent before the cancel.
cancel_sends_write_nothing(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/sends">>)),
    ?assertEqual({closed, <<?CHUNKED_HEAD "3\r\none\r\n">>}, recv_all(Sock)),
    Results = told(sends),
    ?assertEqual(5, length(Results)),
    [?assertMatch({'EXIT', _}, R) || R <- Results].

%% Cancelling a pipelined request that waits behind a response in progress
%% must not cut that response: it ends normally and is the last one. The
%% cancelled request is never answered.
cancel_later_pipelined_stream(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [req(<<"/first">>), req(<<"/second">>)]),
    ?assertEqual({closed, <<?CHUNKED_HEAD "3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n">>},
                 recv_all(Sock)),
    ?assertEqual({error, unknown_stream}, told(later)),
    %% The cancelled request's handler never ran.
    _ = seen(<<"/first">>),
    ?assertEqual(not_seen, not_seen(<<"/second">>)).

%% The first of two pipelined requests is cancelled: the connection closes,
%% and the request read behind it is dropped without running its handler.
%% Input past the cancelled request was read, so the close is staged.
cancel_first_pipelined_stream(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [req(<<"/cut">>), req(<<"/second">>)]),
    Conn = seen(<<"/cut">>),
    MRef = erlang:monitor(process, Conn),
    ?assertEqual({closed, <<?CHUNKED_HEAD "3\r\none\r\n">>}, recv_all(Sock)),
    ?assertEqual(ok, told(cancel)),
    ok = gen_tcp:close(Sock),
    receive {'DOWN', MRef, process, Conn, Reason} ->
        ?assertEqual({shutdown, stream_cancelled}, Reason)
    after 5000 -> ct:fail(connection_still_alive)
    end,
    ?assertEqual(not_seen, not_seen(<<"/second">>)).

%% A cancel while the request body is still arriving: the server has body
%% bytes it never read, so closing outright would answer them with a reset
%% and the client could lose the response bytes already sent. The close is
%% staged (write side shut, input drained), so the client reads them and a
%% clean end of file (RFC 9112 §9.6).
cancel_during_upload(_Config) ->
    %% The server reads at most 1 KiB at a time and stops reading once its
    %% 1 KiB window is full, so body bytes are left unread in the kernel.
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {buffer, 1024}]),
    {ok, Port} = inet:port(L),
    %% Report a reset as such, not as a plain close.
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false},
                                  {show_econnreset, true}]),
    {ok, Accepted} = gen_tcp:accept(L, 5000),
    ok = gen_tcp:close(L),
    Handler = fun(C, Id, _Method, Path, _Hs) ->
                  tell({seen, Path, C}),
                  route(Path, C, Id)
              end,
    {ok, _} = h1:serve_socket(Accepted, #{handler => Handler,
                                          flow_control => manual,
                                          recv_window => 1024}),
    ok = gen_tcp:send(Sock, <<"POST /upload HTTP/1.1\r\nhost: x\r\n"
                              "content-length: 8000000\r\n\r\n">>),
    Sender = spawn(fun() -> send_loop(Sock, binary:copy(<<"b">>, 65536), 100) end),
    Conn = seen(<<"/upload">>),
    MRef = erlang:monitor(process, Conn),
    timer:sleep(200),
    ok = go(),
    ?assertEqual(ok, told(cancel)),
    %% A client slower to read than the server is to close: a reset arriving
    %% meanwhile would discard the response bytes it has not read yet.
    timer:sleep(300),
    %% Sent while the body was still arriving, so it says it is the last.
    ?assertEqual({closed, <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n"
                            "connection: close\r\n\r\n3\r\none\r\n">>},
                 recv_all(Sock)),
    exit(Sender, kill),
    ok = gen_tcp:close(Sock),
    receive {'DOWN', MRef, process, Conn, Reason} ->
        ?assertEqual({shutdown, stream_cancelled}, Reason)
    after 5000 -> ct:fail(connection_still_alive)
    end.

%% Once a response has ended its stream is gone: a second response is
%% refused with `unknown_stream' and nothing is written.
second_response_after_end(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/again">>)),
    Expected = resp(<<"x">>),
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    ?assertEqual({error, unknown_stream}, told(again)),
    ok = gen_tcp:send(Sock, req(<<"/a">>)),
    Next = resp(<<"a">>),
    ?assertEqual(Next, recv_exact(Sock, byte_size(Next))),
    gen_tcp:close(Sock).

%% ----------------------------------------------------------------------------
%% Handler crash
%% ----------------------------------------------------------------------------

%% A handler that crashes after starting its response: a 500 cannot follow,
%% and writing the error text would end the 200 as if it had succeeded. The
%% response is cut short instead (RFC 9112 §8).
crash_after_partial_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/crash-partial">>)),
    ?assertEqual({closed, <<?CHUNKED_HEAD "3\r\none\r\n">>}, recv_all(Sock)).

%% Nothing sent yet: the client gets a 500 and the connection stays.
crash_before_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/crash">>)),
    Expected = <<"HTTP/1.1 500 Internal Server Error\r\ncontent-length: 21\r\n"
                 "content-type: text/plain\r\n\r\nInternal Server Error">>,
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    ok = gen_tcp:send(Sock, req(<<"/a">>)),
    Next = resp(<<"a">>),
    ?assertEqual(Next, recv_exact(Sock, byte_size(Next))),
    gen_tcp:close(Sock).

%% The response had ended: it stays intact and the connection serves the
%% next request.
crash_after_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/crash-done">>)),
    Expected = resp(<<"done">>),
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    ok = gen_tcp:send(Sock, req(<<"/a">>)),
    Next = resp(<<"a">>),
    ?assertEqual(Next, recv_exact(Sock, byte_size(Next))),
    gen_tcp:close(Sock).

%% A stream whose response already ended has nothing left to cancel: the
%% response stays intact on the wire.
cancel_finished_stream(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/done">>)),
    Expected = resp(<<"done">>),
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    ?assertEqual(ok, told(cancel)),
    gen_tcp:close(Sock).

%% ----------------------------------------------------------------------------
%% Unchanged behaviour
%% ----------------------------------------------------------------------------

%% A response that ends normally keeps the connection for the next request.
complete_response_keeps_alive(Config) ->
    Sock = connect(Config),
    Conns = [begin
                 ok = gen_tcp:send(Sock, req(<<"/a">>)),
                 Expected = resp(<<"a">>),
                 ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
                 seen(<<"/a">>)
             end || _ <- lists:seq(1, 3)],
    ?assertMatch([_], lists:usort(Conns)),
    gen_tcp:close(Sock).

%% A client that leaves mid-response is reported to the handler.
client_disconnect_reported(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/wait">>)),
    Head = <<?CHUNKED_HEAD "3\r\none\r\n">>,
    ?assertEqual(Head, recv_exact(Sock, byte_size(Head))),
    ok = gen_tcp:close(Sock),
    ?assertEqual({stream_reset, peer_closed}, told(event)).

%% ----------------------------------------------------------------------------
%% One final response per stream
%% ----------------------------------------------------------------------------

%% A second final response would be written into the body of the first.
second_final_response_refused(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/twice">>)),
    Expected = <<"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok">>,
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    ?assertEqual([{error, response_already_sent},
                  {error, response_already_sent}], told(twice)),
    %% Nothing else was written: the next response starts right here.
    ok = gen_tcp:send(Sock, req(<<"/a">>)),
    Next = resp(<<"a">>),
    ?assertEqual(Next, recv_exact(Sock, byte_size(Next))),
    gen_tcp:close(Sock).

%% An interim response before the final one is still accepted.
interim_then_final_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/hints">>)),
    Expected = <<"HTTP/1.1 103 Early Hints\r\nlink: </a>\r\n\r\n"
                 "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok">>,
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    gen_tcp:close(Sock).

%% ----------------------------------------------------------------------------
%% Client cancel
%% ----------------------------------------------------------------------------
%%
%% The h1 client talks to a raw gen_tcp server, so the close is visible. A
%% client that abandons a request closes the connection too: otherwise the
%% server keeps sending the response, or keeps waiting for the request body.
%% The connection stops with `normal', as after close/1, so an owner that
%% does not trap exits survives its own cancel.

%% No response byte yet: the server reads end of file, and the owner gets
%% the reset and then the close.
client_cancel_before_response(_Config) ->
    {Conn, Srv} = client(),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
    {ok, _Request} = gen_tcp:recv(Srv, 0, 5000),
    ok = h1:cancel(Conn, Id),
    ?assertEqual({error, closed}, gen_tcp:recv(Srv, 0, 3000)),
    ?assertEqual([{stream_reset, Id, cancel},
                  {closed, normal}],
                 events(Conn)).

%% In the middle of a response body: nothing of the response is delivered
%% after the reset, and the connection closes.
client_cancel_mid_response(_Config) ->
    {Conn, Srv} = client(),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
    {ok, _Request} = gen_tcp:recv(Srv, 0, 5000),
    ok = gen_tcp:send(Srv, <<"HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\none">>),
    ?assertMatch({response, Id, 200, _}, event(Conn)),
    ?assertEqual({data, Id, <<"one">>, false}, event(Conn)),
    ok = h1:cancel(Conn, Id),
    ?assertEqual({error, closed}, gen_tcp:recv(Srv, 0, 3000)),
    ?assertEqual([{stream_reset, Id, cancel},
                  {closed, normal}],
                 events(Conn)).

%% In the middle of a request body: the server sees the close instead of
%% waiting for the rest.
client_cancel_mid_upload(_Config) ->
    {Conn, Srv} = client(),
    {ok, Id} = h1:request(Conn, <<"POST">>, <<"/up">>,
                          [{<<"content-length">>, <<"10">>}]),
    ok = h1:send_data(Conn, Id, <<"abc">>, false),
    ok = h1:cancel(Conn, Id),
    {closed, Sent} = recv_all(Srv),
    ?assertEqual(<<"abc">>, binary:part(Sent, byte_size(Sent), -3)),
    ?assertEqual([{stream_reset, Id, cancel},
                  {closed, normal}],
                 events(Conn)).

%% The second of two pipelined requests is cancelled: the first response is
%% still owed and is delivered whole. The second is never delivered, although
%% the server wrote both in one segment, and the connection then closes.
client_cancel_pipelined(_Config) ->
    {Conn, Srv} = client(),
    {ok, Id1} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
    {ok, Id2} = h1:request(Conn, <<"POST">>, <<"/b">>,
                           [{<<"content-length">>, <<"3">>}]),
    ok = h1:cancel(Conn, Id2),
    ?assertEqual({stream_reset, Id2, cancel}, event(Conn)),
    %% Nothing more goes out on the cancelled request, and no new request
    %% is taken.
    ?assertEqual({error, cancelled}, h1:send_data(Conn, Id2, <<"abc">>, true)),
    ?assertEqual({error, closing}, h1:request(Conn, <<"GET">>, <<"/c">>, [])),
    ok = gen_tcp:send(Srv, [resp(<<"a">>), resp(<<"b">>)]),
    {closed, Sent} = recv_all(Srv),
    ?assertEqual(nomatch, binary:match(Sent, <<"abc">>)),
    ?assertEqual(nomatch, binary:match(Sent, <<"/c">>)),
    ?assertMatch([{response, Id1, 200, _},
                  {data, Id1, <<"a">>, true},
                  {closed, normal}],
                 events(Conn)).

%% A request whose response already ended has nothing left to abandon: the
%% connection serves the next request.
client_cancel_finished_stream(_Config) ->
    {Conn, Srv} = client(),
    {ok, Id1} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
    {ok, _} = gen_tcp:recv(Srv, 0, 5000),
    ok = gen_tcp:send(Srv, resp(<<"a">>)),
    ?assertMatch({response, Id1, 200, _}, event(Conn)),
    ?assertEqual({data, Id1, <<"a">>, true}, event(Conn)),
    ok = h1:cancel(Conn, Id1),
    {ok, Id2} = h1:request(Conn, <<"GET">>, <<"/b">>, []),
    {ok, _} = gen_tcp:recv(Srv, 0, 5000),
    ok = gen_tcp:send(Srv, resp(<<"b">>)),
    ?assertMatch({response, Id2, 200, _}, event(Conn)),
    ?assertEqual({data, Id2, <<"b">>, true}, event(Conn)),
    h1:close(Conn),
    gen_tcp:close(Srv).

%% Two of three pipelined requests are cancelled, the later one last. The
%% connection still closes at the earlier one: only the first response is
%% delivered, although the server wrote all three in one segment.
client_cancel_two_pipelined(_Config) ->
    {Conn, Srv, [Id1, Id2, Id3]} = three_requests(),
    ok = h1:cancel(Conn, Id2),
    ok = h1:cancel(Conn, Id3),
    ok = gen_tcp:send(Srv, [resp(<<"a">>), resp(<<"b">>), resp(<<"c">>)]),
    ?assertMatch([{stream_reset, Id2, cancel},
                  {stream_reset, Id3, cancel},
                  {response, Id1, 200, _},
                  {data, Id1, <<"a">>, true},
                  {closed, normal}],
                 events(Conn)),
    gen_tcp:close(Srv).

%% The same, cancelling the later request first.
client_cancel_two_pipelined_reversed(_Config) ->
    {Conn, Srv, [Id1, Id2, Id3]} = three_requests(),
    ok = h1:cancel(Conn, Id3),
    ok = h1:cancel(Conn, Id2),
    ok = gen_tcp:send(Srv, [resp(<<"a">>), resp(<<"b">>), resp(<<"c">>)]),
    ?assertMatch([{stream_reset, Id3, cancel},
                  {stream_reset, Id2, cancel},
                  {response, Id1, 200, _},
                  {data, Id1, <<"a">>, true},
                  {closed, normal}],
                 events(Conn)),
    gen_tcp:close(Srv).

%% While the connection closes for a cancel, an upgrade is refused like a
%% new request: writing it, or resetting the parser, would corrupt the
%% response still being read.
client_upgrade_while_closing(_Config) ->
    {Conn, Srv} = client(),
    {ok, Id1} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
    {ok, Id2} = h1:request(Conn, <<"GET">>, <<"/b">>, []),
    ok = h1:cancel(Conn, Id2),
    ?assertEqual({stream_reset, Id2, cancel}, event(Conn)),
    ?assertEqual({error, closing},
                 h1:upgrade(Conn, <<"websocket">>, [], 1000)),
    ok = gen_tcp:send(Srv, resp(<<"a">>)),
    {closed, Sent} = recv_all(Srv),
    ?assertEqual(nomatch, binary:match(string:lowercase(Sent), <<"upgrade">>)),
    ?assertMatch([{response, Id1, 200, _},
                  {data, Id1, <<"a">>, true},
                  {closed, normal}],
                 events(Conn)).

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

%% Three pipelined requests, all read by the raw server.
three_requests() ->
    {Conn, Srv} = client(),
    Ids = [begin
               {ok, Id} = h1:request(Conn, <<"GET">>, P, []),
               Id
           end || P <- [<<"/a">>, <<"/b">>, <<"/c">>]],
    ok = recv_requests(Srv, 3, <<>>),
    {Conn, Srv, Ids}.

recv_requests(_Srv, 0, _Acc) ->
    ok;
recv_requests(Srv, N, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [_, Rest] -> recv_requests(Srv, N - 1, Rest);
        [_] ->
            {ok, More} = gen_tcp:recv(Srv, 0, 5000),
            recv_requests(Srv, N, <<Acc/binary, More/binary>>)
    end.

send_loop(_Sock, _Chunk, 0) ->
    ok;
send_loop(Sock, Chunk, N) ->
    case gen_tcp:send(Sock, Chunk) of
        ok -> send_loop(Sock, Chunk, N - 1);
        {error, _} -> ok
    end.

%% `not_seen' when no handler ran for `Path' within a short wait.
not_seen(Path) ->
    receive {seen, Path, _} -> seen
    after 300 -> not_seen
    end.

%% An h1 client connected to a raw server socket held by the test.
client() ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}]),
    {ok, Port} = inet:port(L),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Srv} = gen_tcp:accept(L, 5000),
    ok = gen_tcp:close(L),
    ok = h1:wait_connected(Conn),
    receive {h1, Conn, connected} -> ok after 5000 -> ct:fail(not_connected) end,
    {Conn, Srv}.

%% The next event the client connection sent to its owner.
event(Conn) ->
    receive {h1, Conn, Event} -> Event
    after 5000 -> ct:fail(no_event)
    end.

%% Every event up to the close, or up to a second of silence.
events(Conn) ->
    receive
        {h1, Conn, {closed, _} = Event} -> [Event];
        {h1, Conn, Event} -> [Event | events(Conn)]
    after 1000 -> [still_open]
    end.

req(Path) ->
    [<<"GET ">>, Path, <<" HTTP/1.1\r\nhost: x\r\n\r\n">>].

resp(Body) ->
    Len = integer_to_binary(byte_size(Body)),
    <<"HTTP/1.1 200 OK\r\ncontent-length: ", Len/binary, "\r\n\r\n", Body/binary>>.

connect(Config) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", ?config(port, Config),
                                 [binary, {active, false}]),
    Sock.

%% Read until the server closes. `closed' is a clean close; a connection
%% the server leaves open shows as `{still_open, Bytes}'.
recv_all(Sock) ->
    recv_all(Sock, <<>>).

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 3000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> {closed, Acc};
        {error, econnreset} -> {reset, Acc};
        {error, timeout} -> {still_open, Acc}
    end.

recv_exact(Sock, N) ->
    {ok, Bin} = gen_tcp:recv(Sock, N, 5000),
    Bin.

%% The connection that served `Path'.
seen(Path) ->
    receive {seen, Path, Conn} -> Conn
    after 5000 -> ct:fail({no_handler, Path})
    end.

told(Tag) ->
    receive {Tag, Value} -> Value
    after 5000 -> ct:fail({nothing_told, Tag})
    end.
