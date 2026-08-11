%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc End-to-end tests for `h1:serve_socket/2': the caller owns the
%%% listen socket, accepts, and (over TLS) completes the handshake and ALPN
%%% itself, then hands the connected socket to h1. This is the shape a
%%% multiplexing server uses to serve HTTP/1.1 and HTTP/2 on one TLS port.
-module(h1_serve_socket_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).

-export([
    tcp_serves_request/1,
    tcp_keep_alive/1,
    tcp_limits_are_honoured/1,
    tcp_missing_handler/1,
    tcp_owner_death_closes_socket/1,
    tls_alpn_http_1_1/1
]).

all() ->
    Base = [tcp_serves_request, tcp_keep_alive, tcp_limits_are_honoured,
            tcp_missing_handler, tcp_owner_death_closes_socket],
    case os:find_executable("openssl") of
        false -> Base;
        _ -> Base ++ [tls_alpn_http_1_1]
    end.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    application:stop(h1),
    ok.

%% ----------------------------------------------------------------------------
%% Handler
%% ----------------------------------------------------------------------------

echo_handler(Conn, StreamId, _Method, Path, _Headers) ->
    ok = h1:respond(Conn, StreamId, 200,
                    [{<<"content-type">>, <<"text/plain">>}], Path).

%% ----------------------------------------------------------------------------
%% Tests
%% ----------------------------------------------------------------------------

%% A socket accepted outside the library serves a request.
tcp_serves_request(_Config) ->
    {Listen, Port} = listen_tcp(),
    try
        Sock = connect_tcp(Port),
        {ok, Accepted} = gen_tcp:accept(Listen, 5000),
        {ok, _Pid} = h1:serve_socket(Accepted, #{handler => fun echo_handler/5}),
        ok = gen_tcp:send(Sock, <<"GET /hello HTTP/1.1\r\nhost: x\r\n\r\n">>),
        ?assertMatch({200, _, <<"/hello">>}, recv_response(Sock)),
        gen_tcp:close(Sock)
    after
        gen_tcp:close(Listen)
    end.

%% Keep-alive works: a second request on the same handed-off socket is
%% served by the same connection process.
tcp_keep_alive(_Config) ->
    {Listen, Port} = listen_tcp(),
    try
        Sock = connect_tcp(Port),
        {ok, Accepted} = gen_tcp:accept(Listen, 5000),
        {ok, _Pid} = h1:serve_socket(Accepted, #{handler => fun echo_handler/5}),
        ok = gen_tcp:send(Sock, <<"GET /one HTTP/1.1\r\nhost: x\r\n\r\n">>),
        ?assertMatch({200, _, <<"/one">>}, recv_response(Sock)),
        ok = gen_tcp:send(Sock, <<"GET /two HTTP/1.1\r\nhost: x\r\n\r\n">>),
        ?assertMatch({200, _, <<"/two">>}, recv_response(Sock)),
        gen_tcp:close(Sock)
    after
        gen_tcp:close(Listen)
    end.

%% Parser limits passed to serve_socket/2 reach the connection, and a breach
%% is answered exactly as it is on a start_server/2 listener.
tcp_limits_are_honoured(_Config) ->
    {Listen, Port} = listen_tcp(),
    try
        Sock = connect_tcp(Port),
        {ok, Accepted} = gen_tcp:accept(Listen, 5000),
        {ok, _Pid} = h1:serve_socket(Accepted,
                                     #{handler => fun echo_handler/5,
                                       max_request_line_size => 128}),
        Path = binary:copy(<<"x">>, 512),
        ok = gen_tcp:send(Sock, [<<"GET /">>, Path,
                                 <<" HTTP/1.1\r\nhost: x\r\n\r\n">>]),
        {Status, Hdrs, _} = recv_response(Sock),
        ?assertEqual(414, Status),
        ?assertEqual(<<"close">>, header(<<"connection">>, Hdrs)),
        gen_tcp:close(Sock)
    after
        gen_tcp:close(Listen)
    end.

tcp_missing_handler(_Config) ->
    {Listen, Port} = listen_tcp(),
    try
        Sock = connect_tcp(Port),
        {ok, Accepted} = gen_tcp:accept(Listen, 5000),
        ?assertEqual({error, {missing_required_option, [handler]}},
                     h1:serve_socket(Accepted, #{})),
        gen_tcp:close(Accepted),
        gen_tcp:close(Sock)
    after
        gen_tcp:close(Listen)
    end.

%% The returned process is linked to the caller and owns the socket: killing
%% the caller takes the connection (and the socket) with it.
tcp_owner_death_closes_socket(_Config) ->
    {Listen, Port} = listen_tcp(),
    try
        Sock = connect_tcp(Port),
        Self = self(),
        %% serve_socket/2 must be called by the socket's owner, so the
        %% short-lived owner process accepts it as well.
        Owner = spawn(fun() ->
            {ok, Accepted} = gen_tcp:accept(Listen, 5000),
            {ok, Pid} = h1:serve_socket(Accepted,
                                        #{handler => fun echo_handler/5}),
            Self ! {serving, Pid},
            receive stop -> ok end
        end),
        Pid = receive {serving, P} -> P after 5000 -> ct:fail(no_serve) end,
        MRef = erlang:monitor(process, Pid),
        exit(Owner, kill),
        receive
            {'DOWN', MRef, process, Pid, _} -> ok
        after 5000 -> ct:fail(connection_survived_owner)
        end,
        ?assertEqual({error, closed}, gen_tcp:recv(Sock, 0, 5000)),
        gen_tcp:close(Sock)
    after
        gen_tcp:close(Listen)
    end.

%% TLS terminated by the caller: it handshakes, checks the negotiated ALPN
%% protocol, and only then hands the socket to h1 — which must not handshake
%% again.
tls_alpn_http_1_1(Config) ->
    {CertFile, KeyFile} = make_cert(?config(priv_dir, Config)),
    {ok, Listen} = ssl:listen(0, [binary, {active, false}, {packet, raw},
                                  {reuseaddr, true},
                                  {certfile, CertFile}, {keyfile, KeyFile},
                                  {alpn_preferred_protocols,
                                   [<<"h2">>, <<"http/1.1">>]}]),
    try
        {ok, {_, Port}} = ssl:sockname(Listen),
        Parent = self(),
        _ = spawn_link(fun() ->
            {ok, Sock} = ssl:connect("localhost", Port,
                                     [binary, {active, false}, {packet, raw},
                                      {verify, verify_none},
                                      {server_name_indication, "localhost"},
                                      {alpn_advertised_protocols,
                                       [<<"http/1.1">>]}], 5000),
            ok = ssl:send(Sock, <<"GET /tls HTTP/1.1\r\nhost: x\r\n\r\n">>),
            Parent ! {client, recv_response(ssl, Sock)}
        end),
        {ok, Raw} = ssl:transport_accept(Listen, 5000),
        {ok, Accepted} = ssl:handshake(Raw, 5000),
        ?assertEqual({ok, <<"http/1.1">>}, ssl:negotiated_protocol(Accepted)),
        {ok, _Pid} = h1:serve_socket(Accepted, #{handler => fun echo_handler/5}),
        Resp = receive {client, R} -> R after 10000 -> ct:fail(no_response) end,
        ?assertMatch({200, _, <<"/tls">>}, Resp)
    after
        ssl:close(Listen)
    end.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

listen_tcp() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, raw},
                                      {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listen),
    {Listen, Port}.

connect_tcp(Port) ->
    {ok, Sock} = gen_tcp:connect("127.0.0.1", Port,
                                 [binary, {active, false}, {packet, raw}]),
    Sock.

recv_response(Sock) -> recv_response(gen_tcp, Sock).

%% `gen_tcp:recv/3' and `ssl:recv/3' share a signature, so the same reader
%% serves both the plain and the TLS cases.
recv_response(Mod, Sock) ->
    {Head, Rest} = recv_until_headers(Mod, Sock, <<>>),
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_Version, StatusBin | _] = binary:split(StatusLine, <<" ">>, [global]),
    Hdrs = [parse_header(L) || L <- HeaderLines, L =/= <<>>],
    CL = case header(<<"content-length">>, Hdrs) of
        undefined -> 0;
        V -> binary_to_integer(V)
    end,
    {binary_to_integer(StatusBin), Hdrs, recv_body(Mod, Sock, Rest, CL)}.

recv_until_headers(Mod, Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, _} ->
            <<Head:Pos/binary, _:4/binary, Rest/binary>> = Acc,
            {Head, Rest};
        nomatch ->
            case Mod:recv(Sock, 0, 5000) of
                {ok, Data} ->
                    recv_until_headers(Mod, Sock, <<Acc/binary, Data/binary>>);
                {error, R} -> ct:fail({headers_recv_failed, R, Acc})
            end
    end.

recv_body(_Mod, _Sock, Acc, CL) when byte_size(Acc) >= CL ->
    binary:part(Acc, 0, CL);
recv_body(Mod, Sock, Acc, CL) ->
    case Mod:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_body(Mod, Sock, <<Acc/binary, Data/binary>>, CL);
        {error, R} -> ct:fail({body_recv_failed, R, Acc})
    end.

parse_header(Line) ->
    [Name, Value] = binary:split(Line, <<":">>),
    {string:lowercase(string:trim(Name)), string:trim(Value)}.

header(Name, Hdrs) -> proplists:get_value(Name, Hdrs).

make_cert(PrivDir) ->
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
