%%% @doc Reference Ranch protocol module wiring an h1_connection to an
%%% accepted socket. Used by `h1_ranch_SUITE' but also a runnable
%%% example of the shape documented in `docs/ranch.md'.
%%%
%%% Handler dispatch serialises requests per connection so pipelined
%%% responses stay in order on the wire (RFC 9112 §9.3), matching the
%%% behaviour of the in-tree `h1_server'.
-module(h1_ranch_protocol).
-behaviour(ranch_protocol).

-export([start_link/3]).
-export([init/3]).

start_link(Ref, Transport, Opts) ->
    {ok, proc_lib:spawn_link(?MODULE, init, [Ref, Transport, Opts])}.

init(Ref, Transport, #{handler := Handler} = Opts) ->
    process_flag(trap_exit, true),
    {ok, Socket} = ranch:handshake(Ref),
    TransportMod = case Transport of
        ranch_ssl -> ssl;
        ranch_tcp -> gen_tcp
    end,
    ConnOpts = maps:without([handler], Opts),
    {ok, Conn} = h1_connection:start_link(server, Socket, self(), ConnOpts),
    case TransportMod:controlling_process(Socket, Conn) of
        ok ->
            ok = h1_connection:activate(Conn),
            loop(Conn, Handler);
        {error, _} = E ->
            catch h1_connection:close(Conn),
            exit({controlling_process, E})
    end.

loop(Conn, Handler) ->
    receive
        {h1, Conn, {request, Id, Method, Path, Headers}} ->
            {Pid, MRef} = start_handler(Conn, Id, Method, Path,
                                        Headers, Handler),
            pump(Conn, Handler, Pid, MRef, Id);
        {h1, Conn, {upgrade, Id, _Proto, Method, Path, Headers}} ->
            {Pid, MRef} = start_handler(Conn, Id, Method, Path,
                                        Headers, Handler),
            pump(Conn, Handler, Pid, MRef, Id);
        {h1, Conn, {upgraded, _, _, _, _, _}} -> ok;
        {h1, Conn, {closed, _}} -> ok;
        {'EXIT', Conn, _}       -> ok;
        _Other                  -> loop(Conn, Handler)
    end.

pump(Conn, Handler, Pid, MRef, Id) ->
    receive
        {h1, Conn, {data, Id, D, End}} ->
            Pid ! {h1_stream, Id, {data, D, End}},
            pump(Conn, Handler, Pid, MRef, Id);
        {h1, Conn, {trailers, Id, Tr}} ->
            Pid ! {h1_stream, Id, {trailers, Tr}},
            pump(Conn, Handler, Pid, MRef, Id);
        {h1, Conn, {stream_reset, Id, R}} ->
            Pid ! {h1_stream, Id, {stream_reset, R}},
            pump(Conn, Handler, Pid, MRef, Id);
        {'DOWN', MRef, process, Pid, _} ->
            loop(Conn, Handler);
        {h1, Conn, {closed, _}} -> ok;
        {'EXIT', Conn, _}       -> ok
    end.

start_handler(Conn, Id, Method, Path, Headers, Handler) ->
    spawn_monitor(fun() ->
        try invoke(Handler, Conn, Id, Method, Path, Headers)
        catch Class:Reason:Stack ->
            error_logger:error_msg("ranch-h1 handler crash ~p:~p~n~p~n",
                                   [Class, Reason, Stack]),
            catch h1:send_response(Conn, Id, 500,
                [{<<"content-length">>, <<"21">>},
                 {<<"content-type">>, <<"text/plain">>}]),
            catch h1:send_data(Conn, Id, <<"Internal Server Error">>, true)
        end
    end).

invoke(Fun, Conn, Id, M, P, Hs) when is_function(Fun, 5) ->
    Fun(Conn, Id, M, P, Hs);
invoke(Mod, Conn, Id, M, P, Hs) when is_atom(Mod) ->
    Mod:handle_request(Conn, Id, M, P, Hs).
