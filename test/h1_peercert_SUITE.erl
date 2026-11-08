%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc `h1:peercert/1': the certificate the peer presented during the TLS
%%% handshake, read from a request handler (server) or a client connection.
-module(h1_peercert_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).

-export([server_sees_client_cert/1,
         after_accept_upgrade/1,
         after_accept_connect/1,
         tls_without_client_cert/1,
         cleartext/1,
         client_sees_server_cert/1]).

all() ->
    case os:find_executable("openssl") of
        false -> {skip, no_openssl};
        _ -> [server_sees_client_cert, after_accept_upgrade,
              after_accept_connect,
              tls_without_client_cert, cleartext, client_sees_server_cert]
    end.

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(h1),
    %% priv_dir is shared by every suite in a run and other suites write
    %% certificates under the same names; ssl caches PEM files by name, so
    %% keep ours apart.
    Dir = filename:join(?config(priv_dir, Config), "h1_peercert"),
    ok = filelib:ensure_path(Dir),
    [{certs, make_ca_signed_certs(Dir)} | Config].

end_per_suite(_Config) ->
    ok.

%% ----------------------------------------------------------------------------
%% Tests
%% ----------------------------------------------------------------------------

%% A server asking for client certificates sees the DER of the one the client
%% presented.
server_sees_client_cert(Config) ->
    #{client_cert := CliPem, client_key := CliKey} = Certs = ?config(certs, Config),
    Ref = start_mtls_server(Certs, report_handler(self())),
    try
        Sock = tls_connect(Ref, [{certfile, CliPem}, {keyfile, CliKey}]),
        ok = ssl:send(Sock, get_request()),
        ?assertEqual({ok, pem_to_der(CliPem)}, receive_peercert()),
        _ = ssl:close(Sock)
    after
        h1:stop_server(Ref)
    end.

%% Once accept_upgrade/3 has handed the socket over, the connection process
%% is gone and answers `{error, closed}'; peercert/1 on the returned socket
%% still gives the certificate.
after_accept_upgrade(Config) ->
    #{client_cert := CliPem, client_key := CliKey} = Certs = ?config(certs, Config),
    Test = self(),
    Handler = fun(Conn, StreamId, _Method, _Path, _Headers) ->
        Before = h1:peercert(Conn),
        {ok, Sock, _Buf} = h1:accept_upgrade(Conn, StreamId, []),
        Test ! {peercert, Before, h1:peercert(Conn), h1:peercert(Sock)},
        receive done -> ok after 5000 -> ok end
    end,
    Ref = start_mtls_server(Certs, Handler),
    try
        Sock = tls_connect(Ref, [{certfile, CliPem}, {keyfile, CliKey}]),
        ok = ssl:send(Sock, <<"GET / HTTP/1.1\r\nhost: localhost\r\n"
                              "connection: upgrade\r\nupgrade: test\r\n\r\n">>),
        Der = pem_to_der(CliPem),
        receive
            {peercert, Before, FromConn, FromSocket} ->
                ?assertEqual({ok, Der}, Before),
                ?assertEqual({error, closed}, FromConn),
                ?assertEqual({ok, Der}, FromSocket)
        after 5000 -> error(timeout)
        end,
        _ = ssl:close(Sock)
    after
        h1:stop_server(Ref)
    end.

%% Same for a CONNECT tunnel: the socket accept_connect/3 returns carries
%% the certificate.
after_accept_connect(Config) ->
    #{client_cert := CliPem, client_key := CliKey} = Certs = ?config(certs, Config),
    Test = self(),
    Handler = fun(Conn, StreamId, _Method, _Path, _Headers) ->
        {ok, ssl, Sock, _Buf} = h1:accept_connect(Conn, StreamId, []),
        Test ! {peercert, h1:peercert(Sock)},
        receive done -> ok after 5000 -> ok end
    end,
    Ref = start_mtls_server(Certs, Handler),
    try
        Sock = tls_connect(Ref, [{certfile, CliPem}, {keyfile, CliKey}]),
        ok = ssl:send(Sock, <<"CONNECT example.com:443 HTTP/1.1\r\n"
                              "host: example.com:443\r\n\r\n">>),
        ?assertEqual({ok, pem_to_der(CliPem)}, receive_peercert()),
        _ = ssl:close(Sock)
    after
        h1:stop_server(Ref)
    end.

%% A TLS server that does not ask for a certificate gets none.
tls_without_client_cert(Config) ->
    #{cert := Cert, key := Key} = ?config(certs, Config),
    {ok, Ref} = h1:start_server(0, #{transport => ssl, cert => Cert, key => Key,
                                     handler => report_handler(self()),
                                     acceptors => 1}),
    try
        Sock = tls_connect(Ref, []),
        ok = ssl:send(Sock, get_request()),
        ?assertEqual({error, no_peercert}, receive_peercert()),
        _ = ssl:close(Sock)
    after
        h1:stop_server(Ref)
    end.

cleartext(_Config) ->
    {ok, Ref} = h1:start_server(0, #{handler => report_handler(self()),
                                     acceptors => 1}),
    try
        {ok, Sock} = gen_tcp:connect("127.0.0.1", h1:server_port(Ref),
                                     [binary, {active, false}], 5000),
        ok = gen_tcp:send(Sock, get_request()),
        ?assertEqual({error, no_peercert}, receive_peercert()),
        _ = gen_tcp:close(Sock)
    after
        h1:stop_server(Ref)
    end.

%% On a client connection, peercert/1 returns the server's certificate.
client_sees_server_cert(Config) ->
    #{cert := SrvPem, key := Key} = ?config(certs, Config),
    {ok, Ref} = h1:start_server(0, #{transport => ssl, cert => SrvPem, key => Key,
                                     handler => report_handler(self()),
                                     acceptors => 1}),
    try
        {ok, Conn} = h1:connect("localhost", h1:server_port(Ref),
                                #{transport => ssl,
                                  ssl_opts => [{verify, verify_none}]}),
        ?assertEqual({ok, pem_to_der(SrvPem)}, h1:peercert(Conn)),
        h1:close(Conn)
    after
        h1:stop_server(Ref)
    end.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

report_handler(Test) ->
    fun(Conn, StreamId, _Method, _Path, _Headers) ->
        Test ! {peercert, h1:peercert(Conn)},
        h1:respond(Conn, StreamId, 200, [], <<"ok">>)
    end.

receive_peercert() ->
    receive {peercert, R} -> R after 5000 -> error(timeout) end.

get_request() ->
    <<"GET / HTTP/1.1\r\nhost: localhost\r\n\r\n">>.

start_mtls_server(#{ca := CA, cert := Cert, key := Key}, Handler) ->
    {ok, Ref} = h1:start_server(0, #{transport => ssl,
                                     cert => Cert, key => Key,
                                     cacerts => [CA],
                                     verify => verify_peer,
                                     handler => Handler,
                                     acceptors => 1}),
    Ref.

tls_connect(Ref, Extra) ->
    {ok, Sock} = ssl:connect("localhost", h1:server_port(Ref),
                             Extra ++ [binary, {active, false},
                                       {verify, verify_none}], 5000),
    Sock.

pem_to_der(File) ->
    {ok, Pem} = file:read_file(File),
    [{'Certificate', Der, not_encrypted} | _] = public_key:pem_decode(Pem),
    Der.

make_ca_signed_certs(PrivDir) ->
    F = fun(Name) -> filename:join(PrivDir, Name) end,
    CAKey = F("ca-key.pem"), CAPem = F("ca.pem"),
    SrvKey = F("srv-key.pem"), SrvPem = F("srv.pem"), SrvCsr = F("srv.csr"),
    CliKey = F("cli-key.pem"), CliPem = F("cli.pem"), CliCsr = F("cli.csr"),
    Run = fun(Fmt, Args) ->
        _ = os:cmd(lists:flatten(io_lib:format(Fmt ++ " 2>/dev/null", Args)))
    end,
    Run("openssl req -x509 -newkey rsa:2048 -keyout ~s -out ~s -days 1 "
        "-nodes -subj '/CN=h1-test-ca'", [CAKey, CAPem]),
    Sign = fun(Key, Csr, Pem, CN) ->
        Run("openssl req -newkey rsa:2048 -keyout ~s -out ~s -nodes "
            "-subj '/CN=~s'", [Key, Csr, CN]),
        Run("openssl x509 -req -in ~s -CA ~s -CAkey ~s -CAcreateserial "
            "-out ~s -days 1", [Csr, CAPem, CAKey, Pem])
    end,
    Sign(SrvKey, SrvCsr, SrvPem, "localhost"),
    Sign(CliKey, CliCsr, CliPem, "h1-test-client"),
    #{ca => pem_to_der(CAPem), cert => SrvPem, key => SrvKey,
      client_cert => CliPem, client_key => CliKey}.
