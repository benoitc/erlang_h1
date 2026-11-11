%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc Responses that carry no content (RFC 9112 §6.3 item 1, RFC 9110
%%% §6.4.1, §8.6): any response to HEAD and any 1xx, 204 or 304 ends at the
%%% blank line after its header block. The server must put no framing
%%% header that implies a body (no Transfer-Encoding; no Content-Length on
%%% 1xx/204) and no body bytes on the wire, so the next response on the
%%% connection starts right after the header block. The client must not
%%% wait for or consume a body even when a peer advertises one.
%%%
%%% Server cases drive a raw gen_tcp client and assert the exact bytes of
%%% the bodyless response followed by the next response on the same socket.
-module(h1_bodyless_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    s204_send_response_then_empty_data/1,
    s204_send_response_pipelined/1,
    s204_respond_empty/1,
    s204_respond_drops_body_and_framing/1,
    s204_streamed_data_dropped/1,
    s204_trailers_end_stream/1,
    s204_connection_close/1,
    s304_keeps_content_length/1,
    s304_respond_drops_body/1,
    head_respond_sets_content_length/1,
    head_respond_keeps_caller_content_length/1,
    head_respond_empty_body/1,
    head_streamed/1,
    head_streamed_trailers/1,
    head_404_respond/1,
    s1xx_send_response_then_final/1,
    s1xx_respond_then_final/1,
    s1xx_informational_strips_framing/1,
    s1xx_send_response_rejects_101/1,
    c204_with_transfer_encoding/1,
    c204_with_content_length/1,
    c304_with_content_length/1,
    chead_with_content_length/1,
    chead_with_transfer_encoding/1,
    c1xx_then_final/1,
    framing_property/1
]).

all() ->
    [{group, server}, {group, client}, framing_property].

groups() ->
    [{server, [],
      [s204_send_response_then_empty_data, s204_send_response_pipelined,
       s204_respond_empty, s204_respond_drops_body_and_framing,
       s204_streamed_data_dropped, s204_trailers_end_stream,
       s204_connection_close,
       s304_keeps_content_length, s304_respond_drops_body,
       head_respond_sets_content_length,
       head_respond_keeps_caller_content_length, head_respond_empty_body,
       head_streamed, head_streamed_trailers, head_404_respond,
       s1xx_send_response_then_final, s1xx_respond_then_final,
       s1xx_informational_strips_framing, s1xx_send_response_rejects_101]},
     {client, [],
      [c204_with_transfer_encoding, c204_with_content_length,
       c304_with_content_length, chead_with_content_length,
       chead_with_transfer_encoding, c1xx_then_final]}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(server, Config) ->
    Handler = fun(Conn, Id, Method, Path, _Hs) ->
                  handle(Conn, Id, Method, Path)
              end,
    {ok, Ref} = h1:start_server(0, #{transport => tcp, handler => Handler,
                                    acceptors => 2}),
    [{server, Ref}, {port, h1:server_port(Ref)} | Config];
init_per_group(_, Config) ->
    Config.

end_per_group(server, Config) ->
    h1:stop_server(?config(server, Config));
end_per_group(_, _Config) ->
    ok.

%% Handlers report their send results to the running case.
init_per_testcase(_TC, Config) ->
    true = register(?MODULE, self()),
    Config.

end_per_testcase(_TC, _Config) ->
    unregister(?MODULE),
    ok.

%% ----------------------------------------------------------------------------
%% Server handler: one route per case. Every send result is reported to the
%% test process so a case can assert the calls succeeded.
%% ----------------------------------------------------------------------------

-define(CL, <<"content-length">>).
-define(TE, <<"transfer-encoding">>).

handle(Conn, Id, Method, Path) ->
    Results = route(Method, Path, Conn, Id),
    ?MODULE ! {handler_results, Path, Results},
    ok.

route(_, <<"/next">>, C, Id) ->
    [h1:respond(C, Id, 200, [], <<"ok">>)];
route(_, <<"/204">>, C, Id) ->
    %% The livery path: header block, then an empty end-of-stream.
    [h1:send_response(C, Id, 204, [{<<"x-a">>, <<"1">>}]),
     h1:send_data(C, Id, <<>>, true)];
route(_, <<"/204-respond">>, C, Id) ->
    [h1:respond(C, Id, 204, [{<<"x-a">>, <<"1">>}], <<>>)];
route(_, <<"/204-junk">>, C, Id) ->
    [h1:respond(C, Id, 204, [{?CL, <<"4">>}, {?TE, <<"chunked">>},
                             {<<"x-a">>, <<"1">>}], <<"junk">>)];
route(_, <<"/204-stream">>, C, Id) ->
    [h1:send_response(C, Id, 204, [{?TE, <<"chunked">>}]),
     h1:send_data(C, Id, <<"abc">>, false),
     h1:send_data(C, Id, [<<"de">>, <<"f">>], true)];
route(_, <<"/204-trailers">>, C, Id) ->
    [h1:send_response(C, Id, 204, []),
     h1:send_trailers(C, Id, [{<<"x-t">>, <<"1">>}])];
route(_, <<"/204-close">>, C, Id) ->
    [h1:send_response(C, Id, 204, []),
     h1:send_data(C, Id, <<>>, true)];
route(_, <<"/304">>, C, Id) ->
    [h1:send_response(C, Id, 304, [{<<"etag">>, <<"\"v1\"">>},
                                   {?CL, <<"42">>}]),
     h1:send_data(C, Id, <<"stale">>, true)];
route(_, <<"/304-respond">>, C, Id) ->
    [h1:respond(C, Id, 304, [{<<"etag">>, <<"\"v1\"">>}], <<"stale">>)];
route(<<"HEAD">>, <<"/head">>, C, Id) ->
    [h1:respond(C, Id, 200, [{<<"content-type">>, <<"text/plain">>}],
                <<"hello">>)];
route(<<"HEAD">>, <<"/head-cl">>, C, Id) ->
    [h1:respond(C, Id, 200, [{?CL, <<"1000">>}], <<"hello">>)];
route(<<"HEAD">>, <<"/head-empty">>, C, Id) ->
    [h1:respond(C, Id, 200, [], <<>>)];
route(<<"HEAD">>, <<"/head-stream">>, C, Id) ->
    [h1:send_response(C, Id, 200, []),
     h1:send_data(C, Id, <<"abc">>, false),
     h1:send_data(C, Id, <<"def">>, true)];
route(<<"HEAD">>, <<"/head-trailers">>, C, Id) ->
    [h1:send_response(C, Id, 200, [{?TE, <<"chunked">>}]),
     h1:send_data(C, Id, <<"abc">>, false),
     h1:send_trailers(C, Id, [{<<"x-t">>, <<"1">>}])];
route(<<"HEAD">>, <<"/head-404">>, C, Id) ->
    [h1:respond(C, Id, 404, [], <<"not found">>)];
route(_, <<"/103">>, C, Id) ->
    [h1:send_response(C, Id, 103, [{<<"link">>, <<"</s.css>; rel=preload">>},
                                   {?TE, <<"chunked">>}]),
     h1:respond(C, Id, 200, [], <<"ok">>)];
route(_, <<"/103-respond">>, C, Id) ->
    [h1:respond(C, Id, 103, [{<<"link">>, <<"</s.css>; rel=preload">>}],
                <<"junk">>),
     h1:respond(C, Id, 200, [], <<"ok">>)];
route(_, <<"/103-info">>, C, Id) ->
    [h1:send_informational(C, Id, 103, [{?CL, <<"0">>},
                                        {<<"link">>, <<"</s.css>">>}]),
     h1:respond(C, Id, 200, [], <<"ok">>)];
route(_, <<"/101">>, C, Id) ->
    [h1:send_response(C, Id, 101, []),
     h1:respond(C, Id, 200, [], <<"ok">>)].

%% ----------------------------------------------------------------------------
%% Server cases
%% ----------------------------------------------------------------------------

-define(NEXT, <<"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok">>).
-define(NEXT_CLOSE,
        <<"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok">>).

s204_send_response_then_empty_data(Config) ->
    exchange(Config, <<"GET">>, <<"/204">>,
             <<"HTTP/1.1 204 No Content\r\nx-a: 1\r\n\r\n">>, [ok, ok]).

%% Both requests in one write: the second must still parse after the 204.
s204_send_response_pipelined(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, [req(<<"GET">>, <<"/204">>, []),
                             req(<<"GET">>, <<"/next">>, [])]),
    Expected = <<"HTTP/1.1 204 No Content\r\nx-a: 1\r\n\r\n", ?NEXT/binary>>,
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    ?assertEqual([ok, ok], results(<<"/204">>)),
    ?assertEqual([ok], results(<<"/next">>)).

s204_respond_empty(Config) ->
    exchange(Config, <<"GET">>, <<"/204-respond">>,
             <<"HTTP/1.1 204 No Content\r\nx-a: 1\r\n\r\n">>, [ok]).

s204_respond_drops_body_and_framing(Config) ->
    exchange(Config, <<"GET">>, <<"/204-junk">>,
             <<"HTTP/1.1 204 No Content\r\nx-a: 1\r\n\r\n">>, [ok]).

s204_streamed_data_dropped(Config) ->
    exchange(Config, <<"GET">>, <<"/204-stream">>,
             <<"HTTP/1.1 204 No Content\r\n\r\n">>, [ok, ok, ok]).

s204_trailers_end_stream(Config) ->
    exchange(Config, <<"GET">>, <<"/204-trailers">>,
             <<"HTTP/1.1 204 No Content\r\n\r\n">>, [ok, ok]).

%% A client asking to close gets the 204 header block, then the close.
s204_connection_close(Config) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"GET">>, <<"/204-close">>, close)),
    ?assertEqual(<<"HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n">>,
                 recv_all(Sock)),
    ?assertEqual([ok, ok], results(<<"/204-close">>)).

%% 304 keeps a caller-set Content-Length (RFC 9110 §8.6) but sends no body.
s304_keeps_content_length(Config) ->
    exchange(Config, <<"GET">>, <<"/304">>,
             <<"HTTP/1.1 304 Not Modified\r\netag: \"v1\"\r\n"
               "content-length: 42\r\n\r\n">>, [ok, ok]).

%% A 304 gets no synthesized Content-Length: the body handed to respond is
%% not the selected representation.
s304_respond_drops_body(Config) ->
    exchange(Config, <<"GET">>, <<"/304-respond">>,
             <<"HTTP/1.1 304 Not Modified\r\netag: \"v1\"\r\n\r\n">>, [ok]).

%% HEAD answered with the GET body: the same Content-Length a GET would get
%% (RFC 9110 §9.3.2), no body bytes.
head_respond_sets_content_length(Config) ->
    exchange(Config, <<"HEAD">>, <<"/head">>,
             <<"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n"
               "content-length: 5\r\n\r\n">>, [ok]).

head_respond_keeps_caller_content_length(Config) ->
    exchange(Config, <<"HEAD">>, <<"/head-cl">>,
             <<"HTTP/1.1 200 OK\r\ncontent-length: 1000\r\n\r\n">>, [ok]).

%% An empty body says nothing about the GET length: no Content-Length.
head_respond_empty_body(Config) ->
    exchange(Config, <<"HEAD">>, <<"/head-empty">>,
             <<"HTTP/1.1 200 OK\r\n\r\n">>, [ok]).

head_streamed(Config) ->
    exchange(Config, <<"HEAD">>, <<"/head-stream">>,
             <<"HTTP/1.1 200 OK\r\n\r\n">>, [ok, ok, ok]).

head_streamed_trailers(Config) ->
    exchange(Config, <<"HEAD">>, <<"/head-trailers">>,
             <<"HTTP/1.1 200 OK\r\n\r\n">>, [ok, ok, ok]).

head_404_respond(Config) ->
    exchange(Config, <<"HEAD">>, <<"/head-404">>,
             <<"HTTP/1.1 404 Not Found\r\ncontent-length: 9\r\n\r\n">>, [ok]).

%% A 1xx sent through send_response is an interim response: no framing
%% headers, no body, and the final response follows on the same stream.
s1xx_send_response_then_final(Config) ->
    exchange_final(Config, <<"/103">>,
                   <<"HTTP/1.1 103 Early Hints\r\n"
                     "link: </s.css>; rel=preload\r\n\r\n">>, [ok, ok]).

s1xx_respond_then_final(Config) ->
    exchange_final(Config, <<"/103-respond">>,
                   <<"HTTP/1.1 103 Early Hints\r\n"
                     "link: </s.css>; rel=preload\r\n\r\n">>, [ok, ok]).

s1xx_informational_strips_framing(Config) ->
    exchange_final(Config, <<"/103-info">>,
                   <<"HTTP/1.1 103 Early Hints\r\nlink: </s.css>\r\n\r\n">>,
                   [ok, ok]).

%% 101 belongs to accept_upgrade/3: send_response refuses it and nothing
%% reaches the wire, so the handler can still answer.
s1xx_send_response_rejects_101(Config) ->
    exchange_final(Config, <<"/101">>, <<>>,
                   [{error, invalid_informational_status}, ok]).

%% ----------------------------------------------------------------------------
%% Client cases: a raw server peer answers two pipelined requests. The first
%% response advertises a body it does not send; the client must deliver it
%% as complete and then deliver the second response.
%% ----------------------------------------------------------------------------

c204_with_transfer_encoding(_Config) ->
    client_exchange(<<"GET">>,
                    <<"HTTP/1.1 204 No Content\r\n"
                      "transfer-encoding: chunked\r\n\r\n">>, 204).

c204_with_content_length(_Config) ->
    client_exchange(<<"GET">>,
                    <<"HTTP/1.1 204 No Content\r\ncontent-length: 10\r\n\r\n">>,
                    204).

c304_with_content_length(_Config) ->
    client_exchange(<<"GET">>,
                    <<"HTTP/1.1 304 Not Modified\r\ncontent-length: 10\r\n\r\n">>,
                    304).

chead_with_content_length(_Config) ->
    client_exchange(<<"HEAD">>,
                    <<"HTTP/1.1 200 OK\r\ncontent-length: 1000\r\n\r\n">>, 200).

chead_with_transfer_encoding(_Config) ->
    client_exchange(<<"HEAD">>,
                    <<"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n">>,
                    200).

c1xx_then_final(_Config) ->
    client_exchange(<<"GET">>,
                    <<"HTTP/1.1 103 Early Hints\r\ncontent-length: 10\r\n\r\n"
                      "HTTP/1.1 204 No Content\r\ncontent-length: 10\r\n\r\n">>,
                    204).

%% ----------------------------------------------------------------------------
%% Property: framing per RFC 9112 §6 over status codes, methods, send paths
%% and body shapes (h1_prop_tests:prop_bodyless_framing/0).
%% ----------------------------------------------------------------------------

framing_property(_Config) ->
    ?assertEqual(true,
                 proper:quickcheck(h1_prop_tests:prop_bodyless_framing(),
                                   [{numtests, 500}, {to_file, user}])).

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

%% Request Path, then GET /next on the same socket. The bytes on the wire
%% must be exactly the bodyless response followed by the next response.
exchange(Config, Method, Path, Expected, Results) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(Method, Path, [])),
    ?assertEqual(Expected, recv_exact(Sock, byte_size(Expected))),
    ?assertEqual(Results, results(Path)),
    ok = gen_tcp:send(Sock, req(<<"GET">>, <<"/next">>, close)),
    ?assertEqual(?NEXT_CLOSE, recv_all(Sock)),
    ?assertEqual([ok], results(<<"/next">>)).

%% The interim response, then the final 200 for the same request.
exchange_final(Config, Path, Interim, Results) ->
    Sock = connect(Config),
    ok = gen_tcp:send(Sock, req(<<"GET">>, Path, close)),
    ?assertEqual(<<Interim/binary, ?NEXT_CLOSE/binary>>, recv_all(Sock)),
    ?assertEqual(Results, results(Path)).

req(Method, Path, Close) ->
    Conn = case Close of
        close -> <<"connection: close\r\n">>;
        _ -> <<>>
    end,
    [Method, " ", Path, " HTTP/1.1\r\nhost: localhost\r\n", Conn, "\r\n"].

connect(Config) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", ?config(port, Config),
                                 [binary, {active, false}]),
    Sock.

results(Path) ->
    receive {handler_results, Path, R} -> R
    after 5000 -> ct:fail({no_handler_results, Path})
    end.

recv_exact(Sock, N) ->
    {ok, Bin} = gen_tcp:recv(Sock, N, 5000),
    %% Anything else already on the wire is a stray body byte.
    ?assertEqual({error, timeout}, gen_tcp:recv(Sock, 0, 200)),
    Bin.

recv_all(Sock) ->
    recv_all(Sock, <<>>).

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, timeout} -> ct:fail({recv_timeout, Acc})
    end.

client_exchange(Method, FirstResponse, FirstStatus) ->
    {ok, LSock} = gen_tcp:listen(0, [binary, {active, false},
                                     {reuseaddr, true}]),
    {ok, Port} = inet:port(LSock),
    Peer = spawn_link(fun() -> raw_peer(LSock, FirstResponse) end),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    ok = h1:wait_connected(Conn),
    {ok, Id1} = h1:request(Conn, Method, <<"/a">>, []),
    {ok, Id2} = h1:request(Conn, <<"GET">>, <<"/b">>, []),
    ?assertEqual({FirstStatus, <<>>}, collect(Conn, Id1)),
    ?assertEqual({200, <<"ok">>}, collect(Conn, Id2)),
    unlink(Peer),
    h1:close(Conn),
    gen_tcp:close(LSock).

%% Read both request heads, then answer them in one write.
raw_peer(LSock, FirstResponse) ->
    {ok, S} = gen_tcp:accept(LSock, 5000),
    ok = read_requests(S, 2, <<>>),
    ok = gen_tcp:send(S, [FirstResponse,
                          <<"HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok">>]),
    receive stop -> ok after 5000 -> ok end.

read_requests(_S, 0, _Acc) -> ok;
read_requests(S, N, Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [_, Rest] -> read_requests(S, N - 1, Rest);
        [_] ->
            {ok, Data} = gen_tcp:recv(S, 0, 5000),
            read_requests(S, N, <<Acc/binary, Data/binary>>)
    end.

collect(Conn, Id) ->
    receive
        {h1, Conn, {response, Id, Status, _Hs}} -> collect_body(Conn, Id, Status, <<>>)
    after 5000 -> ct:fail({no_response, Id})
    end.

collect_body(Conn, Id, Status, Acc) ->
    receive
        {h1, Conn, {data, Id, Data, true}} -> {Status, <<Acc/binary, Data/binary>>};
        {h1, Conn, {data, Id, Data, false}} ->
            collect_body(Conn, Id, Status, <<Acc/binary, Data/binary>>)
    after 5000 -> ct:fail({body_timeout, Id, Status, Acc})
    end.
