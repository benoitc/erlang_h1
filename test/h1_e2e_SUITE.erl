%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc End-to-end tests for h1:start_server/h1:connect over real
%%% gen_tcp (and TLS with a self-signed cert).
-module(h1_e2e_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    get_tcp/1,
    post_content_length/1,
    response_chunked/1,
    response_trailers/1,
    respond_full/1,
    keep_alive/1,
    pipelined/1,
    early_response_unread_body/1,
    early_response_streaming/1,
    early_response_paced_upload/1,
    early_response_drain_bounded/1,
    early_response_drain_disabled/1,
    early_response_respond6_override/1,
    early_response_lingering_timeout_alias/1,
    max_body_size_raised_content_length/1,
    max_body_size_raised_chunked/1,
    max_body_size_infinity/1,
    max_body_size_default_rejects/1,
    get_tls/1,
    server_stop_is_clean/1,
    peername_tcp/1,
    peername_tls/1,
    informational_early_hints/1,
    informational_rejects_invalid/1,
    informational_rejects_http_1_0/1,
    informational_rejects_mid_response/1,
    stop_closes_keepalive/1,
    stop_accepting_keeps_serving/1
]).

all() ->
    Base = [get_tcp, post_content_length, response_chunked, response_trailers,
            respond_full, keep_alive, pipelined, early_response_unread_body,
            early_response_streaming, early_response_paced_upload,
            early_response_drain_bounded, early_response_drain_disabled,
            early_response_respond6_override,
            early_response_lingering_timeout_alias,
            max_body_size_raised_content_length, max_body_size_raised_chunked,
            max_body_size_infinity, max_body_size_default_rejects,
            server_stop_is_clean,
            peername_tcp, informational_early_hints,
            informational_rejects_invalid, informational_rejects_http_1_0,
            informational_rejects_mid_response,
            stop_closes_keepalive, stop_accepting_keeps_serving],
    case os:find_executable("openssl") of
        false -> Base;
        _ -> Base ++ [get_tls, peername_tls]
    end.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    application:stop(h1),
    ok.

init_per_testcase(_TC, Config) -> Config.

end_per_testcase(_TC, Config) ->
    case ?config(server_ref, Config) of
        undefined -> ok;
        Ref -> try h1:stop_server(Ref) catch _:_ -> ok end
    end,
    ok.

%% ----------------------------------------------------------------------------
%% Handlers
%% ----------------------------------------------------------------------------

echo_handler(Conn, StreamId, _Method, _Path, _Headers) ->
    Body = <<"hello world">>,
    ok = h1:send_response(Conn, StreamId, 200,
                          [{<<"content-length">>, integer_to_binary(byte_size(Body))},
                           {<<"content-type">>, <<"text/plain">>}]),
    ok = h1:send_data(Conn, StreamId, Body, true).

echo_body_handler(Conn, StreamId, _Method, _Path, Headers) ->
    Len = case proplists:get_value(<<"content-length">>, Headers) of
        undefined -> 0;
        V -> binary_to_integer(V)
    end,
    Body = collect_body(StreamId, Len, <<>>),
    ok = h1:send_response(Conn, StreamId, 200,
                          [{<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    ok = h1:send_data(Conn, StreamId, Body, true).

collect_body(_StreamId, 0, Acc) -> Acc;
collect_body(StreamId, _Remaining, Acc) ->
    receive
        {h1_stream, StreamId, {data, Chunk, true}} ->
            <<Acc/binary, Chunk/binary>>;
        {h1_stream, StreamId, {data, Chunk, false}} ->
            collect_body(StreamId, 0, <<Acc/binary, Chunk/binary>>);
        {h1_stream, StreamId, {trailers, _}} ->
            Acc
    after 5000 -> Acc
    end.

chunked_handler(Conn, StreamId, _M, _P, _H) ->
    ok = h1:send_response(Conn, StreamId, 200, [{<<"transfer-encoding">>, <<"chunked">>}]),
    ok = h1:send_data(Conn, StreamId, <<"chunk-1-">>, false),
    ok = h1:send_data(Conn, StreamId, <<"chunk-2-">>, false),
    ok = h1:send_data(Conn, StreamId, <<"chunk-3">>, true).

trailer_handler(Conn, StreamId, _M, _P, _H) ->
    ok = h1:send_response(Conn, StreamId, 200,
                          [{<<"transfer-encoding">>, <<"chunked">>},
                           {<<"trailer">>, <<"x-checksum">>}]),
    ok = h1:send_data(Conn, StreamId, <<"body">>, false),
    ok = h1:send_trailers(Conn, StreamId, [{<<"x-checksum">>, <<"deadbeef">>}]).

%% Echo the connection's view of the client address so the test can
%% compare it against the client socket's sockname.
peer_handler(Conn, StreamId, _M, _P, _H) ->
    Body = case h1:peername(Conn) of
        {ok, {IP, Port}} -> peer_binary(IP, Port);
        {error, R} -> iolist_to_binary(io_lib:format("error:~p", [R]))
    end,
    ok = h1:respond(Conn, StreamId, 200,
                    [{<<"content-type">>, <<"text/plain">>}], Body).

early_hints_handler(Conn, StreamId, _M, _P, _H) ->
    ok = h1:send_informational(Conn, StreamId, 103,
        [{<<"link">>, <<"</style.css>; rel=preload; as=style">>}]),
    ok = h1:send_informational(Conn, StreamId, 103,
        [{<<"link">>, <<"</app.js>; rel=preload; as=script">>}]),
    ok = h1:respond(Conn, StreamId, 200, [], <<"hinted">>).

%% respond/5 sends status + headers + body in one write, adding
%% Content-Length and ending the stream.
respond_handler(Conn, StreamId, _M, _P, _H) ->
    ok = h1:respond(Conn, StreamId, 200,
                    [{<<"content-type">>, <<"application/json">>}],
                    <<"{\"ok\":true}">>).

%% Reject on the first body chunk via respond/5, without reading the rest of
%% the request body.
early_413_handler(Conn, StreamId, _M, _P, _H) ->
    receive
        {h1_stream, StreamId, {data, _Chunk, _End}} ->
            ok = h1:respond(Conn, StreamId, 413,
                            [{<<"content-type">>, <<"text/plain">>}],
                            <<"too large">>)
    after 5000 ->
        ok = h1:respond(Conn, StreamId, 413, [], <<"timeout">>)
    end.

%% Same early rejection, but via the streaming send_response + send_data path.
early_413_stream_handler(Conn, StreamId, _M, _P, _H) ->
    receive
        {h1_stream, StreamId, {data, _Chunk, _End}} ->
            ok = h1:send_response(Conn, StreamId, 413,
                                  [{<<"content-length">>, <<"3">>}]),
            ok = h1:send_data(Conn, StreamId, <<"no!">>, true)
    after 5000 -> ok
    end.

%% Early 413 via respond/6 with a per-response drain budget that overrides
%% the listener default (used to drain when the listener disabled it).
early_413_respond6_handler(Conn, StreamId, _M, _P, _H) ->
    receive
        {h1_stream, StreamId, {data, _Chunk, _End}} ->
            ok = h1:respond(Conn, StreamId, 413,
                            [{<<"content-type">>, <<"text/plain">>}],
                            <<"too large">>,
                            #{early_response_drain => {infinity, 30000}})
    after 5000 ->
        ok = h1:respond(Conn, StreamId, 413, [], <<"timeout">>)
    end.

%% Read the whole request body and reply with its total byte count as a
%% short body, so the client's own response cap is never the thing under
%% test when exercising the server-side max_body_size.
count_body_handler(Conn, StreamId, _M, _P, _H) ->
    Total = drain_request_body(StreamId, 0),
    Body = integer_to_binary(Total),
    ok = h1:respond(Conn, StreamId, 200,
                    [{<<"content-type">>, <<"text/plain">>}], Body).

drain_request_body(StreamId, Acc) ->
    receive
        {h1_stream, StreamId, {data, Chunk, true}} ->
            Acc + byte_size(Chunk);
        {h1_stream, StreamId, {data, Chunk, false}} ->
            drain_request_body(StreamId, Acc + byte_size(Chunk));
        {h1_stream, StreamId, {trailers, _}} ->
            Acc
    after 10000 -> Acc
    end.

%% ----------------------------------------------------------------------------
%% Tests
%% ----------------------------------------------------------------------------

get_tcp(Config0) ->
    Config = start_tcp_server(fun echo_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>,
                          [{<<"host">>, <<"localhost">>}]),
    {Status, _Hs, Body} = collect_response(Conn, Id),
    ?assertEqual(200, Status),
    ?assertEqual(<<"hello world">>, Body),
    h1:close(Conn).

post_content_length(Config0) ->
    Config = start_tcp_server(fun echo_body_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    Body = <<"payload-bytes">>,
    {ok, Id} = h1:request(Conn, <<"POST">>, <<"/">>,
                          [{<<"host">>, <<"localhost">>},
                           {<<"content-length">>,
                            integer_to_binary(byte_size(Body))}],
                          Body),
    {Status, _Hs, Out} = collect_response(Conn, Id),
    ?assertEqual(200, Status),
    ?assertEqual(Body, Out),
    h1:close(Conn).

response_chunked(Config0) ->
    Config = start_tcp_server(fun chunked_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>,
                          [{<<"host">>, <<"localhost">>}]),
    {Status, _, Body} = collect_response(Conn, Id),
    ?assertEqual(200, Status),
    ?assertEqual(<<"chunk-1-chunk-2-chunk-3">>, Body),
    h1:close(Conn).

response_trailers(Config0) ->
    Config = start_tcp_server(fun trailer_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>,
                          [{<<"host">>, <<"localhost">>}]),
    {Status, _, Body, Trailers} = collect_response_with_trailers(Conn, Id),
    ?assertEqual(200, Status),
    ?assertEqual(<<"body">>, Body),
    ?assertEqual(<<"deadbeef">>, proplists:get_value(<<"x-checksum">>, Trailers)),
    h1:close(Conn).

respond_full(Config0) ->
    Config = start_tcp_server(fun respond_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id1} = h1:request(Conn, <<"GET">>, <<"/">>,
                           [{<<"host">>, <<"localhost">>}]),
    {Status, Hs, Body} = collect_response(Conn, Id1),
    ?assertEqual(200, Status),
    ?assertEqual(<<"{\"ok\":true}">>, Body),
    %% Coalesced send frames the body with Content-Length, not chunked.
    ?assertEqual(integer_to_binary(byte_size(Body)),
                 proplists:get_value(<<"content-length">>, Hs)),
    ?assertEqual(undefined, proplists:get_value(<<"transfer-encoding">>, Hs)),
    %% The stream ended cleanly, so the keep-alive connection serves again.
    {ok, Id2} = h1:request(Conn, <<"GET">>, <<"/again">>,
                           [{<<"host">>, <<"localhost">>}]),
    {200, _, Body2} = collect_response(Conn, Id2),
    ?assertEqual(<<"{\"ok\":true}">>, Body2),
    h1:close(Conn).

keep_alive(Config0) ->
    Config = start_tcp_server(fun echo_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id1} = h1:request(Conn, <<"GET">>, <<"/one">>,
                           [{<<"host">>, <<"localhost">>}]),
    {200, _, B1} = collect_response(Conn, Id1),
    {ok, Id2} = h1:request(Conn, <<"GET">>, <<"/two">>,
                           [{<<"host">>, <<"localhost">>}]),
    {200, _, B2} = collect_response(Conn, Id2),
    ?assertEqual(<<"hello world">>, B1),
    ?assertEqual(<<"hello world">>, B2),
    ?assertNotEqual(Id1, Id2),
    h1:close(Conn).

pipelined(Config0) ->
    Config = start_tcp_server(fun echo_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id1} = h1:request(Conn, <<"GET">>, <<"/a">>,
                           [{<<"host">>, <<"localhost">>}]),
    {ok, Id2} = h1:request(Conn, <<"GET">>, <<"/b">>,
                           [{<<"host">>, <<"localhost">>}]),
    {200, _, B1} = collect_response(Conn, Id1),
    {200, _, B2} = collect_response(Conn, Id2),
    ?assertEqual(<<"hello world">>, B1),
    ?assertEqual(<<"hello world">>, B2),
    h1:close(Conn).

%% Responding before the request body is fully read must deliver the response
%% (with Connection: close) and then close the socket cleanly, instead of
%% RST-ing mid-upload. A small max_body_size ensures the unread remainder
%% would trip the body cap if the connection were still parsing it.
early_response_unread_body(_Config) ->
    {Status, Hdrs, Body, Close} =
        early_response_probe(fun early_413_handler/5),
    ?assertEqual(413, Status),
    ?assertEqual(<<"close">>, header(<<"connection">>, Hdrs)),
    ?assertEqual(<<"too large">>, Body),
    ?assertEqual({error, closed}, Close),
    ok.

%% Same guarantee on the streaming send_response + send_data(EndStream) path.
early_response_streaming(_Config) ->
    {Status, Hdrs, Body, Close} =
        early_response_probe(fun early_413_stream_handler/5),
    ?assertEqual(413, Status),
    ?assertEqual(<<"close">>, header(<<"connection">>, Hdrs)),
    ?assertEqual(<<"no!">>, Body),
    ?assertEqual({error, closed}, Close),
    ok.

%% A large body uploaded in paced chunks (so the upload outlives the response)
%% is still answered with 413 and the socket closes cleanly afterwards, every
%% time. This is the standalone reproduction harness, adapted to the h1 API.
early_response_paced_upload(_Config) ->
    Opts = #{transport => tcp, handler => fun early_413_handler/5,
             acceptors => 2, max_body_size => 4096},
    {ok, Ref} = h1:start_server(0, Opts),
    try
        Port = h1:server_port(Ref),
        Results = [paced_upload_once(Port, 2 * 1024 * 1024, 64 * 1024, 1)
                   || _ <- lists:seq(1, 5)],
        ?assertEqual([], [R || R <- Results, R =/= {ok, 413}])
    after
        h1:stop_server(Ref)
    end.

%% A small drain budget is honored: with no further inbound body and no peer
%% FIN, the server still closes once the time budget elapses rather than
%% hanging for the 30 s default. The response is delivered first.
early_response_drain_bounded(_Config) ->
    Opts = #{transport => tcp, handler => fun early_413_handler/5,
             acceptors => 1, max_body_size => 4096,
             early_response_drain => {infinity, 300}},
    {ok, Ref} = h1:start_server(0, Opts),
    try
        Port = h1:server_port(Ref),
        Sock = send_head_and_first_chunk(Port, 1000000, 1024),
        {Status, Hdrs, _Body} = recv_http_response(Sock),
        ?assertEqual(413, Status),
        ?assertEqual(<<"close">>, header(<<"connection">>, Hdrs)),
        %% Stall: send nothing more, never close. The 300 ms linger budget
        %% must fire and close the socket well under the 30 s default.
        T0 = erlang:monotonic_time(millisecond),
        ?assertEqual({error, closed}, drain_until_closed(Sock)),
        Elapsed = erlang:monotonic_time(millisecond) - T0,
        ?assert(Elapsed < 3000),
        gen_tcp:close(Sock)
    after
        h1:stop_server(Ref)
    end.

%% early_response_drain => 0 disables the drain: the listener is accepted and
%% the connection closes promptly instead of lingering.
early_response_drain_disabled(_Config) ->
    Opts = #{transport => tcp, handler => fun early_413_handler/5,
             acceptors => 1, max_body_size => 4096,
             early_response_drain => 0},
    {ok, Ref} = h1:start_server(0, Opts),
    try
        Port = h1:server_port(Ref),
        Sock = send_head_and_first_chunk(Port, 1000000, 1024),
        T0 = erlang:monotonic_time(millisecond),
        %% With the drain disabled the socket closes right away; the response
        %% may or may not be read depending on the kernel, but we must not
        %% block for the linger budget.
        _ = drain_until_closed(Sock),
        Elapsed = erlang:monotonic_time(millisecond) - T0,
        ?assert(Elapsed < 3000),
        gen_tcp:close(Sock)
    after
        h1:stop_server(Ref)
    end.

%% A per-response respond/6 budget overrides a listener that disabled the
%% drain, so the paced upload is still answered cleanly.
early_response_respond6_override(_Config) ->
    Opts = #{transport => tcp, handler => fun early_413_respond6_handler/5,
             acceptors => 1, max_body_size => 4096,
             early_response_drain => 0},
    {ok, Ref} = h1:start_server(0, Opts),
    try
        Port = h1:server_port(Ref),
        ?assertEqual({ok, 413},
                     paced_upload_once(Port, 2 * 1024 * 1024, 64 * 1024, 1))
    after
        h1:stop_server(Ref)
    end.

%% The legacy lingering_timeout option still works: it sets the drain's time
%% bound (with no byte cap) and is wired through start_server.
early_response_lingering_timeout_alias(_Config) ->
    Opts = #{transport => tcp, handler => fun early_413_handler/5,
             acceptors => 1, max_body_size => 4096,
             lingering_timeout => 30000},
    {ok, Ref} = h1:start_server(0, Opts),
    try
        Port = h1:server_port(Ref),
        ?assertEqual({ok, 413},
                     paced_upload_once(Port, 2 * 1024 * 1024, 64 * 1024, 1))
    after
        h1:stop_server(Ref)
    end.

%% A server whose max_body_size is raised above the 8 MB default accepts a
%% content-length body larger than the default.
max_body_size_raised_content_length(_Config) ->
    Cap = 32 * 1024 * 1024,
    Size = 20 * 1024 * 1024,
    ?assertEqual(Size, body_cap_probe(Cap, Size, content_length)).

%% Same, framed as a single chunked body: the raised cap admits a chunk
%% whose declared size exceeds the default.
max_body_size_raised_chunked(_Config) ->
    Cap = 32 * 1024 * 1024,
    Size = 20 * 1024 * 1024,
    ?assertEqual(Size, body_cap_probe(Cap, Size, chunked)).

%% max_body_size => infinity disables the cap entirely.
max_body_size_infinity(_Config) ->
    Size = 20 * 1024 * 1024,
    ?assertEqual(Size, body_cap_probe(infinity, Size, content_length)).

%% Without the option the 8 MB default still applies: a 20 MB body is
%% rejected and the connection closes without a 200.
max_body_size_default_rejects(_Config) ->
    Size = 20 * 1024 * 1024,
    ?assertEqual(rejected, body_cap_probe(default, Size, content_length)).

get_tls(Config0) ->
    {CertFile, KeyFile} = make_selfsigned_cert(?config(priv_dir, Config0)),
    Opts = #{transport => ssl,
             cert => CertFile,
             key => KeyFile,
             handler => fun echo_handler/5,
             acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    Config = [{server_ref, Ref} | Config0],
    Port = h1:server_port(Ref),
    {ok, Conn} = h1:connect("localhost", Port,
                            #{transport => ssl,
                              ssl_opts => [{verify, verify_none},
                                           {server_name_indication, "localhost"}]}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>,
                          [{<<"host">>, <<"localhost">>}]),
    {200, _, Body} = collect_response(Conn, Id),
    ?assertEqual(<<"hello world">>, Body),
    h1:close(Conn),
    {save_config, Config}.

server_stop_is_clean(Config0) ->
    Config = start_tcp_server(fun echo_handler/5, Config0),
    Ref = ?config(server_ref, Config),
    Port = h1:server_port(Ref),
    ok = h1:stop_server(Ref),
    timer:sleep(50),
    ?assertMatch({error, _}, gen_tcp:connect("127.0.0.1", Port,
                                             [binary, {active, false}], 500)),
    {save_config, lists:keydelete(server_ref, 1, Config)}.

%% The handler observes the client's address; the raw client compares it
%% against its own sockname.
peername_tcp(Config0) ->
    Config = start_tcp_server(fun peer_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock, <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
    {200, _, Body} = recv_http_response(Sock),
    {ok, {IP, LPort}} = inet:sockname(Sock),
    ?assertEqual(peer_binary(IP, LPort), Body),
    gen_tcp:close(Sock),
    {save_config, Config}.

peername_tls(Config0) ->
    {CertFile, KeyFile} = make_selfsigned_cert(?config(priv_dir, Config0)),
    Opts = #{transport => ssl, cert => CertFile, key => KeyFile,
             handler => fun peer_handler/5, acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    Config = [{server_ref, Ref} | Config0],
    Port = h1:server_port(Ref),
    {ok, Sock} = ssl:connect("localhost", Port,
                             [binary, {active, false}, {packet, raw},
                              {verify, verify_none}], 5000),
    ok = ssl:send(Sock, <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
    Resp = ssl_recv_all(Sock, <<>>),
    {ok, {IP, LPort}} = ssl:sockname(Sock),
    Expected = peer_binary(IP, LPort),
    ?assertMatch({_, _}, binary:match(Resp, Expected)),
    _ = ssl:close(Sock),
    {save_config, Config}.

%% Two 103 Early Hints ahead of the final 200, observed by the h1 client
%% as {informational, _} events in order.
informational_early_hints(Config0) ->
    Config = start_tcp_server(fun early_hints_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>,
                          [{<<"host">>, <<"localhost">>}]),
    {Infos, {Status, _Hs, Body}} = collect_with_informational(Conn, Id),
    ?assertEqual(200, Status),
    ?assertEqual(<<"hinted">>, Body),
    ?assertMatch([{103, _}, {103, _}], Infos),
    [{103, Hs1}, {103, Hs2}] = Infos,
    ?assertEqual(<<"</style.css>; rel=preload; as=style">>,
                 proplists:get_value(<<"link">>, Hs1)),
    ?assertEqual(<<"</app.js>; rel=preload; as=script">>,
                 proplists:get_value(<<"link">>, Hs2)),
    h1:close(Conn),
    {save_config, Config}.

%% 101 and out-of-range statuses are rejected before anything is written.
informational_rejects_invalid(Config0) ->
    TestPid = self(),
    Handler = fun(Conn, Id, _M, _P, _H) ->
        R101 = h1:send_informational(Conn, Id, 101, []),
        R200 = h1:send_informational(Conn, Id, 200, []),
        TestPid ! {inform_results, R101, R200},
        ok = h1:respond(Conn, Id, 200, [], <<"ok">>)
    end,
    Config = start_tcp_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {200, _, <<"ok">>} = simple_get(Port),
    receive
        {inform_results, R101, R200} ->
            ?assertEqual({error, invalid_informational_status}, R101),
            ?assertEqual({error, invalid_informational_status}, R200)
    after 5000 -> ct:fail(no_inform_results)
    end,
    {save_config, Config}.

%% RFC 9110 §15.2: no 1xx to an HTTP/1.0 client.
informational_rejects_http_1_0(Config0) ->
    Handler = fun(Conn, Id, _M, _P, _H) ->
        Body = case h1:send_informational(Conn, Id, 103, []) of
            {error, http_1_0} -> <<"rejected">>;
            Other -> iolist_to_binary(io_lib:format("~p", [Other]))
        end,
        ok = h1:respond(Conn, Id, 200, [], Body)
    end,
    Config = start_tcp_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock, <<"GET / HTTP/1.0\r\n\r\n">>),
    {200, _, Body} = recv_http_response(Sock),
    ?assertEqual(<<"rejected">>, Body),
    gen_tcp:close(Sock),
    {save_config, Config}.

%% Once the final response headers went out, interim sends are refused.
informational_rejects_mid_response(Config0) ->
    TestPid = self(),
    Handler = fun(Conn, Id, _M, _P, _H) ->
        ok = h1:send_response(Conn, Id, 200,
                              [{<<"transfer-encoding">>, <<"chunked">>}]),
        RMid = h1:send_informational(Conn, Id, 103, []),
        TestPid ! {mid_result, RMid},
        ok = h1:send_data(Conn, Id, <<"x">>, true)
    end,
    Config = start_tcp_server(Handler, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {200, _, _} = simple_get(Port),
    receive
        {mid_result, RMid} ->
            ?assertEqual({error, response_already_started}, RMid)
    after 5000 -> ct:fail(no_mid_result)
    end,
    {save_config, Config}.

%% stop_server/1 must close accepted (kept-alive) connections, not just
%% the listen socket, and return only once it has.
stop_closes_keepalive(Config0) ->
    Opts = #{transport => tcp, handler => fun echo_handler/5, acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    Port = h1:server_port(Ref),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock, <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
    {200, _, <<"hello world">>} = recv_http_response(Sock),
    ok = h1:stop_server(Ref),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 2000)),
    ?assertMatch({error, _}, gen_tcp:connect("127.0.0.1", Port,
                                             [binary, {active, false}], 500)),
    gen_tcp:close(Sock),
    {save_config, Config0}.

%% stop_accepting/1 refuses new connections but keeps serving the
%% established ones until stop_server/1.
stop_accepting_keeps_serving(Config0) ->
    Opts = #{transport => tcp, handler => fun echo_handler/5, acceptors => 2},
    {ok, Ref} = h1:start_server(0, Opts),
    Port = h1:server_port(Ref),
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock, <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
    {200, _, _} = recv_http_response(Sock),
    ok = h1:stop_accepting(Ref),
    ?assertMatch({error, _}, gen_tcp:connect("127.0.0.1", Port,
                                             [binary, {active, false}], 500)),
    ok = gen_tcp:send(Sock, <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
    {200, _, <<"hello world">>} = recv_http_response(Sock),
    ok = h1:stop_server(Ref),
    ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 2000)),
    gen_tcp:close(Sock),
    {save_config, Config0}.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

start_tcp_server(Handler, Config) ->
    Opts = #{transport => tcp, handler => Handler, acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    [{server_ref, Ref} | Config].

%% Start a server with the given max_body_size (`default' omits the option),
%% POST a `Size'-byte body framed as `content_length' or `chunked', and return
%% the echoed byte count on success or `rejected' if the server refused the
%% body and closed the connection.
body_cap_probe(Cap, Size, Framing) ->
    %% h1:connect links the client connection to us; when the server rejects
    %% the body and closes, that connection exits {shutdown, peer_closed}.
    %% Trap exits so the signal arrives as a message instead of killing the
    %% test process; the {closed, _} owner event still reports the rejection.
    process_flag(trap_exit, true),
    Opts0 = #{transport => tcp, handler => fun count_body_handler/5,
              acceptors => 1},
    Opts = case Cap of
        default -> Opts0;
        _       -> Opts0#{max_body_size => Cap}
    end,
    {ok, Ref} = h1:start_server(0, Opts),
    try
        Port = h1:server_port(Ref),
        {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
        Body = binary:copy(<<"x">>, Size),
        Headers = case Framing of
            content_length ->
                [{<<"host">>, <<"localhost">>},
                 {<<"content-length">>, integer_to_binary(Size)}];
            chunked ->
                [{<<"host">>, <<"localhost">>}]
        end,
        Result = case h1:request(Conn, <<"POST">>, <<"/upload">>, Headers, Body) of
            {ok, Id} ->
                case collect_response(Conn, Id) of
                    {200, _Hs, Echo} -> binary_to_integer(Echo);
                    {_Other, _, _}   -> rejected
                end;
            {error, _} -> rejected
        end,
        h1:close(Conn),
        Result
    after
        h1:stop_server(Ref)
    end.

%% Start a server with a small body cap, drive a POST whose body is sent in
%% two parts: a small first chunk that reaches the handler, then a large
%% remainder the handler never reads. Returns the parsed response and the
%% result of the recv that observes the socket close.
early_response_probe(Handler) ->
    Opts = #{transport => tcp, handler => Handler, acceptors => 1,
             max_body_size => 4096},
    {ok, Ref} = h1:start_server(0, Opts),
    try
        Port = h1:server_port(Ref),
        {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                     [binary, {active, false}, {packet, raw}]),
        Total = 200000,
        Req = [<<"POST /upload HTTP/1.1\r\n">>,
               <<"host: localhost\r\n">>,
               <<"content-length: ">>, integer_to_binary(Total), <<"\r\n\r\n">>],
        ok = gen_tcp:send(Sock, Req),
        ok = gen_tcp:send(Sock, binary:copy(<<"x">>, 100)),
        %% Let the handler respond and the connection enter lingering close,
        %% then send the rest (would trip max_body_size if still parsed).
        timer:sleep(200),
        _ = gen_tcp:send(Sock, binary:copy(<<"x">>, Total - 100)),
        {Status, Hdrs, Body} = recv_http_response(Sock),
        Close = drain_until_closed(Sock),
        gen_tcp:close(Sock),
        {Status, Hdrs, Body, Close}
    after
        h1:stop_server(Ref)
    end.

%% Open a connection, send the request head (declaring a Total-byte body) plus
%% a `First'-byte first chunk so the handler is dispatched and can early-reject.
%% The rest of the body is left unsent.
send_head_and_first_chunk(Port, Total, First) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}, {packet, raw},
                                  {nodelay, true}, {send_timeout, 15000}]),
    Req = [<<"POST /upload HTTP/1.1\r\n">>,
           <<"host: localhost\r\n">>,
           <<"content-length: ">>, integer_to_binary(Total), <<"\r\n\r\n">>],
    ok = gen_tcp:send(Sock, Req),
    ok = gen_tcp:send(Sock, binary:copy(<<"x">>, First)),
    Sock.

%% Send a Total-byte body in `Chunk'-sized pieces `SleepMs' apart, then read
%% the status. Returns {ok, Status} or {error, Reason}. The client sends the
%% whole body before reading, exposing the early-response/socket-close race.
paced_upload_once(Port, Total, Chunk, SleepMs) ->
    %% Send a small first chunk (under the listener's max_body_size) so the
    %% handler receives it and early-responds, then let the connection enter
    %% lingering close before pacing the large remainder. Those bytes are
    %% drained raw, so the remainder can exceed the cap without tripping it.
    First = 1024,
    Sock = send_head_and_first_chunk(Port, Total, First),
    timer:sleep(200),
    _ = send_paced(Sock, Total - First, Chunk, SleepMs),
    Result = try recv_http_response(Sock) of
        {Status, _Hdrs, _Body} -> {ok, Status}
    catch
        _:Reason -> {error, Reason}
    end,
    gen_tcp:close(Sock),
    Result.

send_paced(_Sock, Remaining, _Chunk, _SleepMs) when Remaining =< 0 -> ok;
send_paced(Sock, Remaining, Chunk, SleepMs) ->
    N = min(Remaining, Chunk),
    case gen_tcp:send(Sock, binary:copy(<<"x">>, N)) of
        ok ->
            timer:sleep(SleepMs),
            send_paced(Sock, Remaining - N, Chunk, SleepMs);
        {error, _} ->
            send_failed
    end.

recv_http_response(Sock) ->
    {Head, Rest} = recv_until_headers(Sock, <<>>),
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_Version, StatusBin | _] = binary:split(StatusLine, <<" ">>, [global]),
    Status = binary_to_integer(StatusBin),
    Hdrs = [parse_header(L) || L <- HeaderLines, L =/= <<>>],
    CL = case header(<<"content-length">>, Hdrs) of
        undefined -> 0;
        V -> binary_to_integer(V)
    end,
    Body = recv_body(Sock, Rest, CL),
    {Status, Hdrs, Body}.

recv_until_headers(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, _} ->
            <<Head:Pos/binary, _:4/binary, Rest/binary>> = Acc,
            {Head, Rest};
        nomatch ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> recv_until_headers(Sock, <<Acc/binary, Data/binary>>);
                {error, R} -> ct:fail({headers_recv_failed, R, Acc})
            end
    end.

recv_body(_Sock, Acc, CL) when byte_size(Acc) >= CL ->
    <<Body:CL/binary, _/binary>> = Acc,
    Body;
recv_body(Sock, Acc, CL) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_body(Sock, <<Acc/binary, Data/binary>>, CL);
        {error, R} -> ct:fail({body_recv_failed, R, Acc})
    end.

drain_until_closed(Sock) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, _} -> drain_until_closed(Sock);
        {error, R} -> {error, R}
    end.

parse_header(Line) ->
    [Name, Value] = binary:split(Line, <<":">>),
    {string:lowercase(string:trim(Name)), string:trim(Value)}.

header(Name, Hdrs) ->
    proplists:get_value(Name, Hdrs).

peer_binary(IP, Port) ->
    iolist_to_binary([inet:ntoa(IP), $:, integer_to_binary(Port)]).

simple_get(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}, {packet, raw}]),
    ok = gen_tcp:send(Sock, <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>),
    Resp = recv_http_response(Sock),
    gen_tcp:close(Sock),
    Resp.

ssl_recv_all(Sock, Acc) ->
    case ssl:recv(Sock, 0, 2000) of
        {ok, Data} -> ssl_recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, _} -> Acc
    end.

%% As collect_response/2, but returns the interim responses seen before
%% the final one, in order.
collect_with_informational(Conn, Id) ->
    collect_with_informational(Conn, Id, []).

collect_with_informational(Conn, Id, Infos) ->
    receive
        {h1, Conn, {informational, Id, S, H}} ->
            collect_with_informational(Conn, Id, [{S, H} | Infos]);
        {h1, Conn, {response, Id, S, H}} ->
            {Status, Hs, Body} = collect_response(Conn, Id, S, H, <<>>),
            {lists:reverse(Infos), {Status, Hs, Body}}
    after 5000 ->
        ct:fail({informational_timeout, Infos})
    end.

collect_response(Conn, Id) ->
    collect_response(Conn, Id, undefined, [], <<>>).

collect_response(Conn, Id, Status, Hs, Body) ->
    receive
        {h1, Conn, {response, Id, S, H}} ->
            collect_response(Conn, Id, S, H, Body);
        {h1, Conn, {informational, Id, _, _}} ->
            collect_response(Conn, Id, Status, Hs, Body);
        {h1, Conn, {data, Id, D, false}} ->
            collect_response(Conn, Id, Status, Hs, <<Body/binary, D/binary>>);
        {h1, Conn, {data, Id, D, true}} ->
            {Status, Hs, <<Body/binary, D/binary>>};
        {h1, Conn, {trailers, Id, _}} ->
            {Status, Hs, Body};
        {h1, Conn, {closed, _}} ->
            {Status, Hs, Body}
    after 5000 ->
        ct:fail({response_timeout, Status, Hs, Body})
    end.

collect_response_with_trailers(Conn, Id) ->
    collect_response_with_trailers(Conn, Id, undefined, [], <<>>, []).

collect_response_with_trailers(Conn, Id, Status, Hs, Body, Tr) ->
    receive
        {h1, Conn, {response, Id, S, H}} ->
            collect_response_with_trailers(Conn, Id, S, H, Body, Tr);
        {h1, Conn, {data, Id, D, false}} ->
            collect_response_with_trailers(Conn, Id, Status, Hs,
                                           <<Body/binary, D/binary>>, Tr);
        {h1, Conn, {data, Id, D, true}} ->
            {Status, Hs, <<Body/binary, D/binary>>, Tr};
        {h1, Conn, {trailers, Id, T}} ->
            {Status, Hs, Body, T};
        {h1, Conn, {closed, _}} ->
            {Status, Hs, Body, Tr}
    after 5000 ->
        ct:fail({trailer_timeout, Status, Hs, Body, Tr})
    end.

make_selfsigned_cert(PrivDir) ->
    CertFile = filename:join(PrivDir, "cert.pem"),
    KeyFile = filename:join(PrivDir, "key.pem"),
    case filelib:is_regular(CertFile) andalso filelib:is_regular(KeyFile) of
        true -> {CertFile, KeyFile};
        false ->
            Cmd = io_lib:format(
                "openssl req -x509 -newkey rsa:2048 -keyout ~s -out ~s "
                "-days 1 -nodes -subj '/CN=localhost' 2>/dev/null",
                [KeyFile, CertFile]),
            _ = os:cmd(lists:flatten(Cmd)),
            {CertFile, KeyFile}
    end.
