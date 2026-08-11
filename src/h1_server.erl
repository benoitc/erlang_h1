%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
%% @doc HTTP/1.1 server connection loop.
%%
%% Each accepted connection spawns an h1_server process. It owns the
%% socket, performs the TLS handshake (in ssl mode), starts an
%% h1_connection in server mode, and dispatches request events to the
%% user handler.
-module(h1_server).

-export([init_accepted/6]).
-export([init_serve/5]).

-type transport() :: gen_tcp | ssl.

%% @doc Serve a socket the caller already accepted (and, for TLS, already
%% handshaked). Waits for `h1:serve_socket/2' to transfer socket ownership,
%% then runs the same connection loop as an accepted connection — no
%% handshake, no listener registration.
-spec init_serve(term(), transport(), term(), map(), map()) -> ok.
init_serve(Socket, Transport, Handler, ConnOpts, ServerOpts) ->
    %% Linked to the caller (h1:serve_socket/2) and to the h1_connection.
    %% Trap exits so a connection that stops with `{shutdown, peer_closed}'
    %% ends this loop quietly instead of taking the caller down with it;
    %% the caller's own exit is handled in connection_loop/2.
    process_flag(trap_exit, true),
    receive
        {h1_server, socket_ready} ->
            run_connection(Socket, Transport, Handler, ConnOpts, ServerOpts);
        {h1_server, transfer_failed} ->
            ok
    after 5000 ->
        close(Transport, Socket)
    end.

-spec init_accepted(pid(), term(), transport(), term(), map(), map()) -> ok.
init_accepted(_Parent, Socket, Transport, Handler, ConnOpts, ServerOpts) ->
    receive
        {h1_acceptor, socket_ready} ->
            handle_accepted(Socket, Transport, Handler, ConnOpts, ServerOpts);
        {h1_acceptor, transfer_failed} ->
            ok
    after 5000 ->
        close(Transport, Socket)
    end.

handle_accepted(Socket, ssl, Handler, ConnOpts, ServerOpts) ->
    HandshakeTimeout = maps:get(handshake_timeout, ServerOpts, 30000),
    case ssl:handshake(Socket, HandshakeTimeout) of
        {ok, TlsSocket} ->
            run_connection(TlsSocket, ssl, Handler, ConnOpts, ServerOpts);
        {error, _Reason} ->
            _ = ssl:close(Socket),
            ok
    end;
handle_accepted(Socket, gen_tcp, Handler, ConnOpts, ServerOpts) ->
    run_connection(Socket, gen_tcp, Handler, ConnOpts, ServerOpts).

run_connection(Socket, Transport, Handler, ConnOpts, ServerOpts) ->
    case h1_connection:start_link(server, Socket, self(), ConnOpts) of
        {ok, Conn} ->
            case transfer(Transport, Socket, Conn) of
                ok ->
                    case h1_connection:activate(Conn) of
                        ok ->
                            notify_listener(ServerOpts, Conn),
                            connection_loop(Conn, Handler);
                        {error, _} ->
                            try h1_connection:close(Conn) catch _:_ -> ok end
                    end;
                {error, _} ->
                    try h1_connection:close(Conn) catch _:_ -> ok end,
                    close(Transport, Socket)
            end;
        {error, _Reason} ->
            close(Transport, Socket)
    end.

%% Tell the listener which h1_connection serves this loop, so stopping
%% the server can close it (and its socket) synchronously.
notify_listener(#{listener := Listener}, Conn) when is_pid(Listener) ->
    Listener ! {h1_conn_up, self(), Conn},
    ok;
notify_listener(_, _Conn) ->
    ok.

transfer(gen_tcp, Socket, Pid) -> gen_tcp:controlling_process(Socket, Pid);
transfer(ssl, Socket, Pid) -> ssl:controlling_process(Socket, Pid).

close(gen_tcp, Sock) -> _ = gen_tcp:close(Sock), ok;
close(ssl, Sock) -> _ = ssl:close(Sock), ok.

%% ----------------------------------------------------------------------------
%% Event loop
%% ----------------------------------------------------------------------------

%% Each request runs in a dedicated handler process so body/trailers can
%% be delivered as `{h1_stream, StreamId, _}' messages. The connection
%% loop waits for the handler to finish before accepting the next
%% request — this keeps pipelined response bytes in order on the wire
%% (RFC 9112 §9.3).
connection_loop(Conn, Handler) ->
    receive
        {h1, Conn, {request, StreamId, Method, Path, Headers}} ->
            {Pid, MRef} = start_handler(Conn, StreamId, Method, Path,
                                        Headers, Handler),
            pump(Conn, Handler, Pid, MRef, StreamId);
        {h1, Conn, {upgrade, StreamId, _Proto, Method, Path, Headers}} ->
            %% Hand the upgrade request to the user handler exactly as a
            %% regular request — it can inspect `Upgrade:' in Headers
            %% and call `h1:accept_upgrade/3' to switch protocols.
            {Pid, MRef} = start_handler(Conn, StreamId, Method, Path,
                                        Headers, Handler),
            pump(Conn, Handler, Pid, MRef, StreamId);
        {h1, Conn, {upgraded, _StreamId, _Proto, _Sock, _Buf}} ->
            ok;
        {h1, Conn, {upgraded, _StreamId, _Proto, _Sock, _Buf, _Hs}} ->
            ok;
        {h1, Conn, {goaway, _, _}} ->
            ok;
        {h1, Conn, {closed, _Reason}} ->
            ok;
        {'EXIT', Conn, _Reason} ->
            ok;
        {'EXIT', _Other, _Reason} ->
            %% The only other process this loop is linked to is the caller of
            %% `h1:serve_socket/2'. It is gone, so take the connection with it.
            close_connection(Conn);
        _Other ->
            connection_loop(Conn, Handler)
    end.

close_connection(Conn) ->
    try h1_connection:close(Conn) catch _:_ -> ok end,
    ok.

pump(Conn, Handler, Pid, MRef, StreamId) ->
    receive
        {h1, Conn, {data, StreamId, Data, End}} ->
            Pid ! {h1_stream, StreamId, {data, Data, End}},
            pump(Conn, Handler, Pid, MRef, StreamId);
        {h1, Conn, {trailers, StreamId, T}} ->
            Pid ! {h1_stream, StreamId, {trailers, T}},
            pump(Conn, Handler, Pid, MRef, StreamId);
        {h1, Conn, {stream_reset, StreamId, R}} ->
            Pid ! {h1_stream, StreamId, {stream_reset, R}},
            pump(Conn, Handler, Pid, MRef, StreamId);
        {'DOWN', MRef, process, Pid, _Reason} ->
            connection_loop(Conn, Handler);
        {h1, Conn, {closed, Reason}} ->
            %% Connection gone mid-stream: unblock the handler (which may be
            %% waiting for the next {h1_stream, _} body chunk) before exiting.
            Pid ! {h1_stream, StreamId, {stream_reset, Reason}},
            ok;
        {'EXIT', Conn, Reason} ->
            Pid ! {h1_stream, StreamId, {stream_reset, Reason}},
            ok;
        {'EXIT', _Other, Reason} ->
            %% Caller of `h1:serve_socket/2' gone mid-stream: unblock the
            %% handler, then close the connection.
            Pid ! {h1_stream, StreamId, {stream_reset, Reason}},
            close_connection(Conn)
    end.

start_handler(Conn, StreamId, Method, Path, Headers, Handler) ->
    spawn_monitor(fun() ->
        try
            invoke(Handler, Conn, StreamId, Method, Path, Headers)
        catch
            Class:Reason:Stack ->
                error_logger:error_msg("h1 handler crashed: ~p:~p~n~p~n",
                                       [Class, Reason, Stack]),
                try
                    h1_connection:send_response(
                        Conn, StreamId, 500,
                        [{<<"content-length">>, <<"21">>},
                         {<<"content-type">>, <<"text/plain">>}]),
                    h1_connection:send_data(
                        Conn, StreamId, <<"Internal Server Error">>, true)
                catch _:_ -> ok end
        end
    end).

invoke(Fun, Conn, StreamId, Method, Path, Headers) when is_function(Fun, 5) ->
    Fun(Conn, StreamId, Method, Path, Headers);
invoke(Mod, Conn, StreamId, Method, Path, Headers) when is_atom(Mod) ->
    Mod:handle_request(Conn, StreamId, Method, Path, Headers).
