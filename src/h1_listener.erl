%% @doc HTTP/1.1 listener: owns the listen socket and supervises the
%% acceptor pool. Runs under `h1_sup' so the listener outlives the
%% process that called `h1:start_server/2'.
-module(h1_listener).

-export([start_link/1, stop/2]).
-export([init/2]).

-type transport() :: gen_tcp | ssl.

-type args() :: #{transport := transport(),
                  listen_socket := term(),
                  acceptor_count := pos_integer(),
                  ref := reference(),
                  handler := term(),
                  conn_opts := map(),
                  server_opts := map()}.

-spec start_link(args()) -> {ok, pid()}.
start_link(Args) ->
    proc_lib:start_link(?MODULE, init, [self(), Args]).

-spec stop(pid(), reference()) -> ok.
stop(Pid, Ref) ->
    Pid ! {stop, Ref},
    ok.

init(Parent, #{transport := Transport,
               listen_socket := ListenSocket,
               acceptor_count := NumAcceptors,
               ref := Ref} = Args) ->
    process_flag(trap_exit, true),
    AcceptorArgs = maps:with(
        [transport, listen_socket, handler, conn_opts, server_opts], Args),
    AcceptorPids = [begin
                        {ok, Pid} = h1_acceptor:start_link(AcceptorArgs),
                        Pid
                    end || _ <- lists:seq(1, NumAcceptors)],
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(Transport, ListenSocket, AcceptorPids, Ref).

loop(Transport, ListenSocket, AcceptorPids, Ref) ->
    receive
        {stop, Ref} ->
            close(Transport, ListenSocket),
            lists:foreach(fun(Pid) -> exit(Pid, shutdown) end, AcceptorPids),
            ok;
        {'EXIT', Pid, _Reason} ->
            loop(Transport, ListenSocket, lists:delete(Pid, AcceptorPids), Ref);
        _ ->
            loop(Transport, ListenSocket, AcceptorPids, Ref)
    end.

close(gen_tcp, Sock) -> _ = gen_tcp:close(Sock), ok;
close(ssl, Sock) -> _ = ssl:close(Sock), ok.
