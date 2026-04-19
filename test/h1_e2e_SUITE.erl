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
    keep_alive/1,
    pipelined/1,
    get_tls/1,
    server_stop_is_clean/1
]).

all() ->
    Base = [get_tcp, post_content_length, response_chunked, response_trailers,
            keep_alive, pipelined, server_stop_is_clean],
    case os:find_executable("openssl") of
        false -> Base;
        _ -> Base ++ [get_tls]
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
        Ref -> catch h1:stop_server(Ref)
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

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

start_tcp_server(Handler, Config) ->
    Opts = #{transport => tcp, handler => Handler, acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    [{server_ref, Ref} | Config].

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
