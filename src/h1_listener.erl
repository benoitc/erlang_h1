%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc HTTP/1.1 listener: owns the listen socket, supervises the
%% acceptor pool, and tracks every accepted connection. Runs under
%% `h1_sup' so the listener outlives the process that called
%% `h1:start_server/2'.
%%
%% Acceptors register each accepted connection-loop process
%% (`{h1_conn_started, Pid}'); the loop registers its h1_connection
%% once it is up (`{h1_conn_up, LoopPid, ConnPid}'). `stop/2' is
%% synchronous: it stops accepting, then closes every tracked
%% connection before returning. `stop_accepting/2' only closes the
%% listen socket and acceptor pool, leaving established connections
%% to finish (graceful drain).
-module(h1_listener).

-export([start_link/1, stop/2, stop_accepting/2]).
-export([init/2]).

-type transport() :: gen_tcp | ssl.

-type args() :: #{transport := transport(),
                  listen_socket := term(),
                  acceptor_count := pos_integer(),
                  ref := reference(),
                  handler := term(),
                  conn_opts := map(),
                  server_opts := map()}.

%% Tracked connections: loop pid -> h1_connection pid, or `undefined'
%% while the loop is still setting up (TLS handshake in progress).
-type conns() :: #{pid() => pid() | undefined}.

-record(st, {
    parent         :: pid(),
    transport      :: transport(),
    listen_socket  :: term(),
    acceptors      :: [pid()],
    ref            :: reference(),
    conns = #{}    :: conns(),
    accepting = true :: boolean()
}).

-spec start_link(args()) -> {ok, pid()}.
start_link(Args) ->
    proc_lib:start_link(?MODULE, init, [self(), Args]).

%% @doc Synchronously stop the listener: close the listen socket, the
%% acceptor pool, and every accepted connection. Returns once all of
%% them are closed (or if the listener is already gone).
-spec stop(pid(), reference()) -> ok.
stop(Pid, Ref) ->
    call(Pid, stop, Ref).

%% @doc Synchronously stop accepting new connections while leaving the
%% established ones running. The listener stays alive to track them; a
%% later `stop/2' closes them.
-spec stop_accepting(pid(), reference()) -> ok.
stop_accepting(Pid, Ref) ->
    call(Pid, stop_accepting, Ref).

call(Pid, What, Ref) ->
    MRef = erlang:monitor(process, Pid),
    Pid ! {What, Ref, {self(), MRef}},
    receive
        {MRef, ok} ->
            erlang:demonitor(MRef, [flush]),
            ok;
        {'DOWN', MRef, process, Pid, _Reason} ->
            ok
    end.

init(Parent, #{transport := Transport,
               listen_socket := ListenSocket,
               acceptor_count := NumAcceptors,
               ref := Ref} = Args) ->
    process_flag(trap_exit, true),
    AcceptorArgs = maps:with(
        [transport, listen_socket, handler, conn_opts, server_opts], Args),
    AcceptorArgs1 = AcceptorArgs#{listener => self()},
    AcceptorPids = [begin
                        {ok, Pid} = h1_acceptor:start_link(AcceptorArgs1),
                        Pid
                    end || _ <- lists:seq(1, NumAcceptors)],
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(#st{parent = Parent,
             transport = Transport,
             listen_socket = ListenSocket,
             acceptors = AcceptorPids,
             ref = Ref}).

loop(#st{ref = Ref} = St) ->
    receive
        {h1_conn_started, Pid} ->
            _ = erlang:monitor(process, Pid),
            loop(St#st{conns = maps:put(Pid, undefined, St#st.conns)});
        {h1_conn_up, LoopPid, ConnPid} ->
            loop(St#st{conns = conn_up(LoopPid, ConnPid, St#st.conns)});
        {'DOWN', _MRef, process, Pid, _Reason} ->
            loop(St#st{conns = maps:remove(Pid, St#st.conns)});
        {stop_accepting, Ref, From} ->
            St1 = do_stop_accepting(St),
            reply(From),
            loop(St1);
        {stop, Ref, From} ->
            St1 = do_stop_accepting(St),
            close_conns(St1#st.conns),
            reply(From),
            ok;
        {'EXIT', Pid, Reason} when Pid =:= St#st.parent ->
            %% Supervisor shutdown: tear everything down like stop/2.
            St1 = do_stop_accepting(St),
            close_conns(St1#st.conns),
            exit(Reason);
        {'EXIT', Pid, _Reason} ->
            loop(St#st{acceptors = lists:delete(Pid, St#st.acceptors)});
        _ ->
            loop(St)
    end.

reply({Pid, Tag}) ->
    Pid ! {Tag, ok},
    ok.

%% Only track the connection if the loop registered first; a late
%% `h1_conn_up' from a loop whose entry was already dropped (DOWN
%% processed first) must not resurrect it.
conn_up(LoopPid, ConnPid, Conns) ->
    case maps:is_key(LoopPid, Conns) of
        true -> maps:put(LoopPid, ConnPid, Conns);
        false -> Conns
    end.

do_stop_accepting(#st{accepting = false} = St) ->
    St;
do_stop_accepting(#st{transport = Transport,
                      listen_socket = ListenSocket,
                      acceptors = Acceptors} = St) ->
    close(Transport, ListenSocket),
    %% Kill the acceptors and wait for their exits so no registration
    %% can arrive after the mailbox drain below: an acceptor sends
    %% `{h1_conn_started, _}' before anything else, so once they are
    %% all down the drain sees every accepted connection. An acceptor
    %% killed between accept and ownership transfer still owned the
    %% socket, so the runtime closes it with the process.
    lists:foreach(fun(Pid) -> exit(Pid, kill) end, Acceptors),
    lists:foreach(
        fun(Pid) ->
            receive {'EXIT', Pid, _} -> ok end
        end,
        Acceptors),
    Conns = drain_registrations(St#st.conns),
    St#st{acceptors = [], conns = Conns, accepting = false}.

drain_registrations(Conns) ->
    receive
        {h1_conn_started, Pid} ->
            _ = erlang:monitor(process, Pid),
            drain_registrations(maps:put(Pid, undefined, Conns));
        {h1_conn_up, LoopPid, ConnPid} ->
            drain_registrations(conn_up(LoopPid, ConnPid, Conns))
    after 0 ->
        Conns
    end.

%% Close every tracked connection. A registered h1_connection closes
%% its socket in terminate (h1_connection:close/1 is synchronous); a
%% loop still mid-setup owns the raw socket itself, so killing the
%% process closes it.
close_conns(Conns) ->
    maps:foreach(
        fun(LoopPid, undefined) -> exit(LoopPid, kill);
           (_LoopPid, ConnPid) -> h1_connection:close(ConnPid)
        end,
        Conns).

close(gen_tcp, Sock) -> _ = gen_tcp:close(Sock), ok;
close(ssl, Sock) -> _ = ssl:close(Sock), ok.
