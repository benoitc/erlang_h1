%%% @doc End-to-end test: drive our h1 client against a Ranch listener
%%% whose protocol module embeds an `h1_connection'. Verifies the
%%% acceptor-handoff pattern documented in `docs/ranch.md'.
-module(h1_ranch_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    tcp_get/1,
    tcp_post_echo/1,
    tcp_chunked_response/1,
    tcp_pipelined/1,
    tcp_drain_on_stop/1,
    tls_get/1
]).

all() ->
    case code:which(ranch) of
        non_existing -> {skip, ranch_not_available};
        _ -> [tcp_get, tcp_post_echo, tcp_chunked_response,
              tcp_pipelined, tcp_drain_on_stop, tls_get]
    end.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    application:stop(h1),
    application:stop(ranch),
    ok.

init_per_testcase(TC, Config) ->
    process_flag(trap_exit, true),
    [{listener, list_to_atom("h1_ranch_" ++ atom_to_list(TC))} | Config].

end_per_testcase(_TC, Config) ->
    catch ranch:stop_listener(?config(listener, Config)),
    ok.

%% ----------------------------------------------------------------------------
%% Handlers
%% ----------------------------------------------------------------------------

simple_handler(Conn, Id, _Method, _Path, _Headers) ->
    Body = <<"hello from ranch">>,
    ok = h1:send_response(Conn, Id, 200,
        [{<<"content-type">>, <<"text/plain">>},
         {<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    ok = h1:send_data(Conn, Id, Body, true).

echo_handler(Conn, Id, _Method, _Path, Headers) ->
    Len = case proplists:get_value(<<"content-length">>, Headers) of
        undefined -> 0;
        V -> binary_to_integer(V)
    end,
    Body = drain_body(Id, Len),
    ok = h1:send_response(Conn, Id, 200,
        [{<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    ok = h1:send_data(Conn, Id, Body, true).

chunked_handler(Conn, Id, _, _, _) ->
    ok = h1:send_response(Conn, Id, 200,
        [{<<"transfer-encoding">>, <<"chunked">>}]),
    ok = h1:send_data(Conn, Id, <<"one-">>,  false),
    ok = h1:send_data(Conn, Id, <<"two-">>,  false),
    ok = h1:send_data(Conn, Id, <<"three">>, true).

drain_body(_Id, 0) -> <<>>;
drain_body(Id, _Remaining) ->
    receive
        {h1_stream, Id, {data, Bin, true}}  -> Bin;
        {h1_stream, Id, {data, Bin, false}} -> <<Bin/binary, (drain_body(Id, 1))/binary>>;
        {h1_stream, Id, _}                  -> <<>>
    after 5000 -> <<>>
    end.

%% ----------------------------------------------------------------------------
%% Tests
%% ----------------------------------------------------------------------------

tcp_get(Config) ->
    Listener = ?config(listener, Config),
    {ok, _, Port} = start_tcp(Listener, fun simple_handler/5, #{}),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>, []),
    {200, _, Body} = collect(Conn, Id),
    ?assertEqual(<<"hello from ranch">>, Body),
    h1:close(Conn).

tcp_post_echo(Config) ->
    Listener = ?config(listener, Config),
    {ok, _, Port} = start_tcp(Listener, fun echo_handler/5, #{}),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    Payload = <<"body-over-ranch">>,
    {ok, Id} = h1:request(Conn, <<"POST">>, <<"/echo">>,
                          [{<<"content-length">>,
                            integer_to_binary(byte_size(Payload))}],
                          Payload),
    {200, _, Body} = collect(Conn, Id),
    ?assertEqual(Payload, Body),
    h1:close(Conn).

tcp_chunked_response(Config) ->
    Listener = ?config(listener, Config),
    {ok, _, Port} = start_tcp(Listener, fun chunked_handler/5, #{}),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>, []),
    {200, _, Body} = collect(Conn, Id),
    ?assertEqual(<<"one-two-three">>, Body),
    h1:close(Conn).

tcp_pipelined(Config) ->
    Listener = ?config(listener, Config),
    {ok, _, Port} = start_tcp(Listener, fun simple_handler/5, #{}),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id1} = h1:request(Conn, <<"GET">>, <<"/a">>, []),
    {ok, Id2} = h1:request(Conn, <<"GET">>, <<"/b">>, []),
    {200, _, B1} = collect(Conn, Id1),
    {200, _, B2} = collect(Conn, Id2),
    ?assertEqual(<<"hello from ranch">>, B1),
    ?assertEqual(<<"hello from ranch">>, B2),
    ?assertNotEqual(Id1, Id2),
    h1:close(Conn).

tcp_drain_on_stop(Config) ->
    Listener = ?config(listener, Config),
    {ok, _, Port} = start_tcp(Listener, fun simple_handler/5, #{}),
    %% Stopping Ranch closes the listen socket; new connects must fail.
    ok = ranch:stop_listener(Listener),
    timer:sleep(100),
    ?assertMatch({error, _},
                 gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}], 500)).

tls_get(Config) ->
    case os:find_executable("openssl") of
        false -> {skip, {missing, "openssl"}};
        _ ->
            {CertFile, KeyFile} = make_cert(?config(priv_dir, Config)),
            Listener = ?config(listener, Config),
            {ok, _, Port} = start_tls(Listener, fun simple_handler/5,
                                      CertFile, KeyFile),
            {ok, Conn} = h1:connect("localhost", Port,
                                    #{transport => ssl,
                                      ssl_opts => [{verify, verify_none},
                                                   {server_name_indication,
                                                    "localhost"}]}),
            {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>, []),
            {200, _, Body} = collect(Conn, Id),
            ?assertEqual(<<"hello from ranch">>, Body),
            h1:close(Conn)
    end.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

start_tcp(Listener, Handler, ExtraOpts) ->
    ProtoOpts = ExtraOpts#{handler => Handler},
    {ok, Pid} = ranch:start_listener(Listener, ranch_tcp,
        #{socket_opts => [{port, 0}, {reuseaddr, true}]},
        h1_ranch_protocol, ProtoOpts),
    Port = ranch:get_port(Listener),
    {ok, Pid, Port}.

start_tls(Listener, Handler, CertFile, KeyFile) ->
    ProtoOpts = #{handler => Handler},
    {ok, Pid} = ranch:start_listener(Listener, ranch_ssl,
        #{socket_opts => [{port, 0},
                          {certfile, CertFile},
                          {keyfile, KeyFile},
                          {alpn_preferred_protocols, [<<"http/1.1">>]}]},
        h1_ranch_protocol, ProtoOpts),
    Port = ranch:get_port(Listener),
    {ok, Pid, Port}.

collect(Conn, Id) -> collect(Conn, Id, undefined, [], <<>>).

collect(Conn, Id, Status, Hs, Body) ->
    receive
        {h1, Conn, connected} ->
            collect(Conn, Id, Status, Hs, Body);
        {h1, Conn, {response, Id, S, H}} ->
            collect(Conn, Id, S, H, Body);
        {h1, Conn, {data, Id, D, false}} ->
            collect(Conn, Id, Status, Hs, <<Body/binary, D/binary>>);
        {h1, Conn, {data, Id, D, true}} ->
            {Status, Hs, <<Body/binary, D/binary>>};
        {h1, Conn, {trailers, Id, _}} ->
            {Status, Hs, Body};
        {h1, Conn, {closed, _}} ->
            {Status, Hs, Body}
    after 5000 ->
        ct:fail({response_timeout, Status, Hs, Body})
    end.

make_cert(PrivDir) ->
    CertFile = filename:join(PrivDir, "cert.pem"),
    KeyFile  = filename:join(PrivDir, "key.pem"),
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
