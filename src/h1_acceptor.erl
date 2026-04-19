%% @doc HTTP/1.1 acceptor loop.
%%
%% One lightweight process per acceptor. Blocks on accept against a
%% shared listen socket, spawns a server loop for each accepted
%% connection, and transfers socket ownership to it.
%%
%% The TLS handshake runs inside the server-loop process (not here) so
%% one slow handshake never blocks the accept queue.
-module(h1_acceptor).

-export([start_link/1]).
-export([loop/1]).

-define(ACCEPT_BACKOFF, 10).

-type transport() :: gen_tcp | ssl.

-type args() :: #{transport := transport(),
                  listen_socket := term(),
                  handler := term(),
                  conn_opts := map(),
                  server_opts := map()}.

-spec start_link(args()) -> {ok, pid()}.
start_link(Args) ->
    Pid = proc_lib:spawn_link(?MODULE, loop, [Args]),
    {ok, Pid}.

-spec loop(args()) -> no_return().
loop(#{transport := Transport, listen_socket := ListenSocket} = Args) ->
    case accept(Transport, ListenSocket) of
        {ok, Socket} ->
            _ = spawn_connection(Socket, Args),
            loop(Args);
        {error, closed} ->
            exit(normal);
        {error, E} when E =:= emfile; E =:= enfile ->
            timer:sleep(?ACCEPT_BACKOFF),
            loop(Args);
        {error, _Reason} ->
            loop(Args)
    end.

accept(gen_tcp, ListenSocket) ->
    gen_tcp:accept(ListenSocket, infinity);
accept(ssl, ListenSocket) ->
    ssl:transport_accept(ListenSocket, infinity).

spawn_connection(Socket, #{transport := Transport,
                           handler := Handler,
                           conn_opts := ConnOpts,
                           server_opts := ServerOpts}) ->
    Parent = self(),
    Pid = erlang:spawn(fun() ->
        h1_server:init_accepted(Parent, Socket, Transport,
                                Handler, ConnOpts, ServerOpts)
    end),
    case controlling_process(Transport, Socket, Pid) of
        ok ->
            Pid ! {h1_acceptor, socket_ready},
            Pid;
        {error, _Reason} ->
            Pid ! {h1_acceptor, transfer_failed},
            close(Transport, Socket),
            Pid
    end.

controlling_process(gen_tcp, Socket, Pid) ->
    gen_tcp:controlling_process(Socket, Pid);
controlling_process(ssl, Socket, Pid) ->
    ssl:controlling_process(Socket, Pid).

close(gen_tcp, Socket) -> gen_tcp:close(Socket);
close(ssl, Socket) -> ssl:close(Socket).
