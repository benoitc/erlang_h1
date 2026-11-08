%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%%% @doc A server must keep accepting connections after the process that
%%% started it exits. The listen socket used to stay owned by the caller,
%%% so it closed with it and every new connection was refused.
-module(h1_listener_owner_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1,
         init_per_group/2, end_per_group/2]).

-export([starter_exits_normally/1,
         starter_killed/1,
         stop_server_from_other_process/1,
         stop_accepting_from_other_process/1,
         failed_transfer_leaves_nothing/1]).

all() ->
    [{group, tcp}, {group, ssl}, failed_transfer_leaves_nothing].

groups() ->
    Cases = [starter_exits_normally,
             starter_killed,
             stop_server_from_other_process,
             stop_accepting_from_other_process],
    [{tcp, [], Cases}, {ssl, [], Cases}].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ssl),
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(tcp, Config) ->
    [{opts, #{transport => tcp}} | Config];
init_per_group(ssl, Config) ->
    {Cert, Key} = make_selfsigned_cert(?config(priv_dir, Config)),
    [{opts, #{transport => ssl, cert => Cert, key => Key}} | Config].

end_per_group(_, _Config) ->
    ok.

%% ----------------------------------------------------------------------------
%% Tests
%% ----------------------------------------------------------------------------

starter_exits_normally(Config) ->
    {Ref, Starter} = start_from_process(Config, normal),
    ?assertNot(is_process_alive(Starter)),
    assert_serves(Config, Ref),
    assert_serves(Config, Ref),
    ok = h1:stop_server(Ref).

starter_killed(Config) ->
    {Ref, Starter} = start_from_process(Config, kill),
    ?assertNot(is_process_alive(Starter)),
    assert_serves(Config, Ref),
    ok = h1:stop_server(Ref).

stop_server_from_other_process(Config) ->
    {Ref, _} = start_from_process(Config, normal),
    assert_serves(Config, Ref),
    {ListenerPid, _, Port} = Ref,
    ok = run_in_process(fun() -> h1:stop_server(Ref) end),
    ?assertNot(is_process_alive(ListenerPid)),
    ?assertMatch({error, _}, gen_tcp:connect("127.0.0.1", Port,
                                             [binary, {active, false}], 500)).

stop_accepting_from_other_process(Config) ->
    {Ref, _} = start_from_process(Config, normal),
    Port = h1:server_port(Ref),
    ok = run_in_process(fun() -> h1:stop_accepting(Ref) end),
    ?assertMatch({error, _}, gen_tcp:connect("127.0.0.1", Port,
                                             [binary, {active, false}], 500)),
    ok = run_in_process(fun() -> h1:stop_server(Ref) end).

%% The listen socket belongs to another process, so the transfer to the
%% listener fails with `not_owner'. The call must report it and leave no
%% listener running.
failed_transfer_leaves_nothing(_Config) ->
    Self = self(),
    Owner = spawn(fun() ->
        {ok, LS} = gen_tcp:listen(0, [binary, {active, false}]),
        Self ! {listen, LS},
        receive stop -> ok end
    end),
    LS = receive {listen, S} -> S after 5000 -> error(no_listen) end,
    {ok, Port} = inet:port(LS),
    Before = h1_listeners(),
    Result = h1:spawn_listener(gen_tcp, LS, Port,
                               #{handler => fun handler/5, acceptors => 2}),
    ?assertEqual({error, {controlling_process, not_owner}}, Result),
    ?assertEqual(Before, h1_listeners()),
    Owner ! stop.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

handler(Conn, StreamId, _Method, _Path, _Headers) ->
    h1:respond(Conn, StreamId, 200, [], <<"hello world">>).

%% Start a server from a short-lived process, then let it return (`normal')
%% or kill it while it waits (`kill').
start_from_process(Config, How) ->
    Opts = maps:merge(?config(opts, Config),
                      #{handler => fun handler/5, acceptors => 2}),
    Self = self(),
    {Pid, MRef} = spawn_monitor(fun() ->
        Self ! {started, self(), h1:start_server(0, Opts)},
        case How of
            normal -> ok;
            kill -> receive never -> ok end
        end
    end),
    {ok, Ref} = receive {started, Pid, R} -> R after 5000 -> error(timeout) end,
    case How of
        normal -> ok;
        kill -> exit(Pid, kill)
    end,
    receive {'DOWN', MRef, process, Pid, _} -> ok after 5000 -> error(timeout) end,
    {Ref, Pid}.

run_in_process(Fun) ->
    {Pid, MRef} = spawn_monitor(fun() -> exit({result, Fun()}) end),
    receive
        {'DOWN', MRef, process, Pid, {result, R}} -> R;
        {'DOWN', MRef, process, Pid, Other} -> error(Other)
    after 10000 -> error(timeout)
    end.

assert_serves(Config, Ref) ->
    Port = h1:server_port(Ref),
    Req = <<"GET / HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n\r\n">>,
    Resp = case maps:get(transport, ?config(opts, Config)) of
        tcp ->
            {ok, S} = gen_tcp:connect("127.0.0.1", Port,
                                      [binary, {active, false}], 5000),
            ok = gen_tcp:send(S, Req),
            recv_all(fun(T) -> gen_tcp:recv(S, 0, T) end, <<>>);
        ssl ->
            {ok, S} = ssl:connect("localhost", Port,
                                  [binary, {active, false},
                                   {verify, verify_none}], 5000),
            ok = ssl:send(S, Req),
            recv_all(fun(T) -> ssl:recv(S, 0, T) end, <<>>)
    end,
    ?assertMatch(<<"HTTP/1.1 200", _/binary>>, Resp),
    ?assertNotEqual(nomatch, binary:match(Resp, <<"hello world">>)).

recv_all(Recv, Acc) ->
    case Recv(5000) of
        {ok, Data} -> recv_all(Recv, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc
    end.

h1_listeners() ->
    lists:sort([P || {_, P, _, _} <- supervisor:which_children(h1_sup)]).

make_selfsigned_cert(PrivDir) ->
    CertFile = filename:join(PrivDir, "cert.pem"),
    KeyFile = filename:join(PrivDir, "key.pem"),
    Cmd = io_lib:format(
        "openssl req -x509 -newkey rsa:2048 -keyout ~s -out ~s "
        "-days 1 -nodes -subj '/CN=localhost' 2>/dev/null",
        [KeyFile, CertFile]),
    _ = os:cmd(lists:flatten(Cmd)),
    {CertFile, KeyFile}.
