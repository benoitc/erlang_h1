%% @doc HTTP/1.1 server connection loop.
%%
%% Each accepted connection spawns an h1_server process. It owns the
%% socket, performs the TLS handshake (in ssl mode), starts an
%% h1_connection in server mode, and dispatches request events to the
%% user handler.
-module(h1_server).

-export([init_accepted/6]).

-type transport() :: gen_tcp | ssl.

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
            run_connection(TlsSocket, ssl, Handler, ConnOpts);
        {error, _Reason} ->
            _ = ssl:close(Socket),
            ok
    end;
handle_accepted(Socket, gen_tcp, Handler, ConnOpts, _ServerOpts) ->
    run_connection(Socket, gen_tcp, Handler, ConnOpts).

run_connection(Socket, Transport, Handler, ConnOpts) ->
    case h1_connection:start_link(server, Socket, self(), ConnOpts) of
        {ok, Conn} ->
            case transfer(Transport, Socket, Conn) of
                ok ->
                    case h1_connection:activate(Conn) of
                        ok ->
                            connection_loop(Conn, Handler);
                        {error, _} ->
                            catch h1_connection:close(Conn)
                    end;
                {error, _} ->
                    catch h1_connection:close(Conn),
                    close(Transport, Socket)
            end;
        {error, _Reason} ->
            close(Transport, Socket)
    end.

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
        _Other ->
            connection_loop(Conn, Handler)
    end.

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
        {h1, Conn, {closed, _Reason}} ->
            ok;
        {'EXIT', Conn, _Reason} ->
            ok
    end.

start_handler(Conn, StreamId, Method, Path, Headers, Handler) ->
    spawn_monitor(fun() ->
        try
            invoke(Handler, Conn, StreamId, Method, Path, Headers)
        catch
            Class:Reason:Stack ->
                error_logger:error_msg("h1 handler crashed: ~p:~p~n~p~n",
                                       [Class, Reason, Stack]),
                catch h1_connection:send_response(
                    Conn, StreamId, 500,
                    [{<<"content-length">>, <<"21">>},
                     {<<"content-type">>, <<"text/plain">>}]),
                catch h1_connection:send_data(
                    Conn, StreamId, <<"Internal Server Error">>, true)
        end
    end).

invoke(Fun, Conn, StreamId, Method, Path, Headers) when is_function(Fun, 5) ->
    Fun(Conn, StreamId, Method, Path, Headers);
invoke(Mod, Conn, StreamId, Method, Path, Headers) when is_atom(Mod) ->
    Mod:handle_request(Conn, StreamId, Method, Path, Headers).
