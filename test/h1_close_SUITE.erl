%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc Connection close on the server side (RFC 9112 §9.6, §9.3.2).
%%%
%%% A request carrying `Connection: close' makes its own response the last
%%% one: earlier pipelined responses keep the connection open, later
%%% pipelined requests are not processed. A response the handler sends with
%%% `Connection: close' closes the connection after it. When bytes were read
%%% past the last request, the close is staged (write side shut first, the
%%% rest drained) so a reset cannot wipe out the last response. A response
%%% ended with trailers finishes its stream like a final send_data.
%%%
%%% Each case drives a raw gen_tcp client and asserts the exact bytes.
-module(h1_close_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    pipelined_close_on_second/1,
    pipelined_close_on_first/1,
    pipelined_close_late_bytes/1,
    http10_pipelined/1,
    handler_close/1,
    handler_close_streamed/1,
    handler_close_token/1,
    handler_close_pipelined/1,
    trailers_request_close/1,
    trailers_keepalive_no_leak/1,
    trailers_early_response/1
]).

all() ->
    [pipelined_close_on_second, pipelined_close_on_first,
     pipelined_close_late_bytes, http10_pipelined,
     handler_close, handler_close_streamed, handler_close_token,
     handler_close_pipelined,
     trailers_request_close, trailers_keepalive_no_leak,
     trailers_early_response].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Handler = fun(Conn, Id, _Method, Path, _Hs) ->
                  case whereis(?MODULE) of
                      undefined -> ok;
                      Test -> Test ! {seen, Path, Conn}
                  end,
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

route(<<"/hclose">>, C, Id) ->
    h1:respond(C, Id, 200, [{<<"connection">>, <<"close">>}], <<"x">>);
route(<<"/hclose-stream">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, [{<<"connection">>, <<"close">>},
                                       {<<"content-length">>, <<"1">>}]),
    h1:send_data(C, Id, <<"x">>, true);
route(<<"/hclose-token">>, C, Id) ->
    h1:respond(C, Id, 200, [{<<"Connection">>, <<"keep-alive, Close">>}],
               <<"x">>);
route(<<"/slow">>, C, Id) ->
    timer:sleep(300),
    h1:respond(C, Id, 200, [], <<"slow">>);
route(<<"/trailers">>, C, Id) ->
    ok = h1:send_response(C, Id, 200, []),
    ok = h1:send_data(C, Id, <<"ab">>, false),
    h1:send_trailers(C, Id, [{<<"x-t">>, <<"1">>}]);
route(<<"/", Name/binary>>, C, Id) ->
    %% Plain route: the body is the path without its slash.
    h1:respond(C, Id, 200, [], Name).

%% ----------------------------------------------------------------------------
%% Request asking to close
%% ----------------------------------------------------------------------------

%% A, B (close), C in one write: A keeps the connection, B is the last
%% response, C is never processed.
pipelined_close_on_second(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [req(<<"/a">>, []), req(<<"/b">>, close),
                             req(<<"/c">>, [])]),
    ?assertEqual({closed, <<(resp(<<"a">>))/binary,
                           (resp_close(<<"b">>))/binary>>},
                 recv_all(Sock)),
    ?assertEqual([<<"/a">>, <<"/b">>], seen()).

%% A (close) then B in one write: only A is answered, and the close is
%% clean although B was read (no reset).
pipelined_close_on_first(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [req(<<"/a">>, close), req(<<"/b">>, [])]),
    ?assertEqual({closed, resp_close(<<"a">>)}, recv_all(Sock)),
    ?assertEqual([<<"/a">>], seen()).

%% A request arriving after the last one, while its response is pending, is
%% read and discarded, and the close is staged so the last response is not
%% lost to a reset.
pipelined_close_late_bytes(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/slow">>, close)),
    timer:sleep(100),
    ok = gen_tcp:send(Sock, req(<<"/b">>, [])),
    ?assertEqual({closed, resp_close(<<"slow">>)}, recv_all(Sock)),
    ?assertEqual([<<"/slow">>], seen()).

%% An HTTP/1.0 request without keep-alive asks to close too.
http10_pipelined(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [<<"GET /a HTTP/1.0\r\n\r\n">>, req(<<"/b">>, [])]),
    ?assertEqual({closed, resp_close(<<"a">>)}, recv_all(Sock)),
    ?assertEqual([<<"/a">>], seen()).

%% ----------------------------------------------------------------------------
%% Handler answering with Connection: close
%% ----------------------------------------------------------------------------

handler_close(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/hclose">>, [])),
    ?assertEqual({closed, <<"HTTP/1.1 200 OK\r\nconnection: close\r\n"
                            "content-length: 1\r\n\r\nx">>},
                 recv_all(Sock)),
    ?assertEqual([<<"/hclose">>], seen()).

handler_close_streamed(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/hclose-stream">>, [])),
    ?assertEqual({closed, <<"HTTP/1.1 200 OK\r\nconnection: close\r\n"
                            "content-length: 1\r\n\r\nx">>},
                 recv_all(Sock)),
    ?assertEqual([<<"/hclose-stream">>], seen()).

%% The close token is found in any case and position of the value.
handler_close_token(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/hclose-token">>, [])),
    ?assertEqual({closed, <<"HTTP/1.1 200 OK\r\nConnection: keep-alive, Close\r\n"
                            "content-length: 1\r\n\r\nx">>},
                 recv_all(Sock)),
    ?assertEqual([<<"/hclose-token">>], seen()).

%% B was already read when the handler closed on A: B gets no answer on the
%% wire and the close is clean.
handler_close_pipelined(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [req(<<"/hclose">>, []), req(<<"/b">>, [])]),
    ?assertEqual({closed, <<"HTTP/1.1 200 OK\r\nconnection: close\r\n"
                            "content-length: 1\r\n\r\nx">>},
                 recv_all(Sock)).

%% ----------------------------------------------------------------------------
%% Trailers end the stream
%% ----------------------------------------------------------------------------

-define(TRAILERS_BODY, "2\r\nab\r\n0\r\nx-t: 1\r\n\r\n").

trailers_request_close(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"/trailers">>, close)),
    ?assertEqual({closed, <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n"
                            "connection: close\r\n\r\n" ?TRAILERS_BODY>>},
                 recv_all(Sock)),
    ?assertEqual([<<"/trailers">>], seen()).

%% Three responses with trailers on one kept-alive connection leave no
%% stream behind.
trailers_keepalive_no_leak(Config) ->
    Sock = connect(Config),
    Expected = <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
                 ?TRAILERS_BODY>>,
    Conns = [begin
                 ok = gen_tcp:send(Sock, req(<<"/trailers">>, [])),
                 ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
                 receive {seen, <<"/trailers">>, C} -> C
                 after 5000 -> ct:fail(no_handler)
                 end
             end || _ <- lists:seq(1, 3)],
    [Conn] = lists:usort(Conns),
    ?assertEqual(0, stream_count(Conn)),
    gen_tcp:close(Sock).

%% A response ended with trailers while the request body is still arriving:
%% Connection: close goes out and the server closes its write side once the
%% trailers are sent, without waiting for the rest of the body.
trailers_early_response(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, <<"POST /trailers HTTP/1.1\r\nhost: x\r\n"
                              "content-length: 100000\r\n\r\npartial">>),
    Expected = <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n"
                 "connection: close\r\n\r\n" ?TRAILERS_BODY>>,
    ?assertEqual({closed, Expected}, recv_all(Sock)),
    gen_tcp:close(Sock).

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

req(Path, Close) ->
    Conn = case Close of
        close -> <<"connection: close\r\n">>;
        _ -> <<>>
    end,
    [<<"GET ">>, Path, <<" HTTP/1.1\r\nhost: x\r\n">>, Conn, <<"\r\n">>].

resp(Body) ->
    Len = integer_to_binary(byte_size(Body)),
    <<"HTTP/1.1 200 OK\r\ncontent-length: ", Len/binary, "\r\n\r\n", Body/binary>>.

resp_close(Body) ->
    Len = integer_to_binary(byte_size(Body)),
    <<"HTTP/1.1 200 OK\r\ncontent-length: ", Len/binary,
      "\r\nconnection: close\r\n\r\n", Body/binary>>.

connect(Config) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", ?config(port, Config),
                                 [binary, {active, false}]),
    Sock.

%% Read until the server closes. `closed' is a clean close; a reset shows
%% as `{reset, Bytes}'.
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

%% Paths the handler saw, in order, once the connection has had time to
%% start any further handler.
seen() ->
    seen([]).

seen(Acc) ->
    receive {seen, Path, _Conn} -> seen([Path | Acc])
    after 300 -> lists:reverse(Acc)
    end.

%% Streams held by a connection process. The state is not public API.
stream_count(Conn) ->
    {_StateName, State} = sys:get_state(Conn),
    lists:sum([length([S || S <- maps:values(M),
                           is_tuple(S), element(1, S) =:= stream])
               || M <- tuple_to_list(State), is_map(M)]).
