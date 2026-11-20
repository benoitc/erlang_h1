%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc Cancelling a stream on the server side.
%%%
%%% HTTP/1.1 has no stream reset: a server that will not finish a response
%%% can only say so by closing the connection, and the client then records
%%% the message as incomplete (RFC 9112 §8; §6.3 item 6 for a
%%% Content-Length body cut short). `h1:cancel/2,3' on a stream whose
%%% response has not ended therefore closes the connection, whether or not
%%% a response byte went out. A response that ends normally keeps the
%%% connection alive, and a client that leaves is still reported to the
%%% handler.
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
    interim_then_final_response/1
]).

all() ->
    [cancel_chunked_response, cancel_content_length_response,
     cancel_before_response, cancel_after_interim_response,
     cancel_sends_write_nothing, cancel_later_pipelined_stream,
     cancel_finished_stream, complete_response_keeps_alive,
     client_disconnect_reported,
     second_final_response_refused, interim_then_final_response].

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
route(<<"/", Name/binary>>, C, Id) ->
    h1:respond(C, Id, 200, [], Name).

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
    ?assertEqual({error, unknown_stream}, told(later)).

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
%% Helpers
%% ----------------------------------------------------------------------------

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
