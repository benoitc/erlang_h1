%% @doc HTTP/1.1 Upgrade + capsule passthrough helpers.
%%
%% Upgrade handshake itself is done by `h1_connection' (client:
%% `h1:upgrade/3,4'; server: `h1:accept_upgrade/3'). After a successful
%% handshake the caller owns the raw socket and any leftover buffer.
%%
%% This module provides the thin capsule-over-socket helpers a consumer
%% (e.g. masque for RFC 9298 CONNECT-UDP) needs on that raw socket:
%% framing a capsule and reading one back, with an incremental buffer
%% so partial reads don't drop bytes.
%%
%% The capsule wire format (RFC 9297) lives in `h1_capsule'. This
%% module stays protocol-agnostic — it knows nothing about
%% connect-udp, connect-ip, or any specific capsule type.
-module(h1_upgrade).

-export([send_capsule/4]).
-export([recv_capsule/3, recv_capsule/4]).
-export([close/2]).

-type transport() :: gen_tcp | ssl.
-type socket() :: gen_tcp:socket() | ssl:sslsocket().
-type capsule() :: {atom() | non_neg_integer(), binary()}.

-export_type([transport/0, socket/0, capsule/0]).

%% @doc Encode a capsule and send it on the raw socket.
-spec send_capsule(transport(), socket(),
                   atom() | non_neg_integer(), iodata()) ->
    ok | {error, term()}.
send_capsule(Transport, Socket, Type, Payload) ->
    Wire = h1_capsule:encode(Type, iolist_to_binary(Payload)),
    send(Transport, Socket, Wire).

%% @doc Read exactly one capsule from the socket, reusing any bytes
%% already in `Buffer'. Returns the decoded capsule plus the leftover
%% buffer, ready to be passed back into the next call.
-spec recv_capsule(transport(), socket(), binary()) ->
    {ok, capsule(), binary()} | {error, term()}.
recv_capsule(Transport, Socket, Buffer) ->
    recv_capsule(Transport, Socket, Buffer, infinity).

-spec recv_capsule(transport(), socket(), binary(), timeout()) ->
    {ok, capsule(), binary()} | {error, term()}.
recv_capsule(Transport, Socket, Buffer, Timeout) ->
    case h1_capsule:decode(Buffer) of
        {ok, Capsule, Rest} ->
            {ok, Capsule, Rest};
        {more, _} ->
            case recv(Transport, Socket, Timeout) of
                {ok, Bin} ->
                    recv_capsule(Transport, Socket,
                                 <<Buffer/binary, Bin/binary>>, Timeout);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec close(transport(), socket()) -> ok.
close(gen_tcp, S) -> _ = gen_tcp:close(S), ok;
close(ssl, S) -> _ = ssl:close(S), ok.

%% Internal

send(gen_tcp, Socket, Data) -> gen_tcp:send(Socket, Data);
send(ssl, Socket, Data) -> ssl:send(Socket, Data).

recv(gen_tcp, Socket, Timeout) -> gen_tcp:recv(Socket, 0, Timeout);
recv(ssl, Socket, Timeout) -> ssl:recv(Socket, 0, Timeout).
