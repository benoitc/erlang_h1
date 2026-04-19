%% @doc HTTP/1.1 client connect helpers.
%%
%% Opens a TCP or TLS socket, starts an h1_connection in client mode,
%% transfers socket ownership, activates the connection, and waits for
%% the `connected' event (matching h2's connect/activate/wait_connected
%% sequence).
-module(h1_client).

-export([connect/3]).

-type host() :: string() | binary() | inet:ip_address().

-spec connect(host(), inet:port_number(), map()) ->
    {ok, pid()} | {error, term()}.
connect(Host, Port, Opts) when is_binary(Host) ->
    connect(binary_to_list(Host), Port, Opts);
connect(Host, Port, Opts) ->
    Transport = maps:get(transport, Opts, tcp),
    Timeout = maps:get(connect_timeout, Opts, 30000),
    case Transport of
        tcp -> connect_tcp(Host, Port, Opts, Timeout);
        ssl -> connect_ssl(Host, Port, Opts, Timeout)
    end.

connect_tcp(Host, Port, Opts, Timeout) ->
    TcpOpts = [{active, false}, {mode, binary}, {packet, raw}],
    case gen_tcp:connect(Host, Port, TcpOpts, Timeout) of
        {ok, Socket} -> start_connection(Host, Socket, gen_tcp, Opts, Timeout);
        {error, Reason} -> {error, Reason}
    end.

connect_ssl(Host, Port, Opts, Timeout) ->
    Defaults = [{active, false}, {mode, binary},
                {alpn_advertised_protocols, [<<"http/1.1">>]},
                %% RFC 9110 §4.2.2: TLS clients MUST verify the
                %% server's identity. Previously we relied on the OTP
                %% default, which was `verify_none' on older releases.
                {verify, verify_peer},
                {cacerts, cacerts()},
                {customize_hostname_check,
                    [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]
               ++ sni_opt(Host),
    SSLOpts = merge(Defaults, maps:get(ssl_opts, Opts, [])),
    case ssl:connect(Host, Port, SSLOpts, Timeout) of
        {ok, Socket} -> start_connection(Host, Socket, ssl, Opts, Timeout);
        {error, Reason} -> {error, Reason}
    end.

cacerts() ->
    try public_key:cacerts_get()
    catch _:_ -> []
    end.

sni_opt(Host) when is_list(Host) ->
    case is_ip_literal(Host) of
        true  -> [];
        false -> [{server_name_indication, Host}]
    end;
sni_opt(_) -> [].

is_ip_literal(H) ->
    case inet:parse_address(H) of
        {ok, _} -> true;
        _       -> false
    end.

start_connection(Host, Socket, Transport, Opts, Timeout) ->
    ConnOpts0 = maps:without([transport, ssl_opts, connect_timeout, timeout], Opts),
    ConnOpts = ConnOpts0#{peer_host => peer_host_bin(Host)},
    case h1_connection:start_link(client, Socket, self(), ConnOpts) of
        {ok, Pid} ->
            case transfer(Transport, Socket, Pid) of
                ok ->
                    _ = h1_connection:activate(Pid),
                    case h1_connection:wait_connected(Pid, Timeout) of
                        ok -> {ok, Pid};
                        {error, Reason} ->
                            catch h1_connection:close(Pid),
                            {error, Reason}
                    end;
                {error, TReason} ->
                    catch h1_connection:close(Pid),
                    close(Transport, Socket),
                    {error, {controlling_process_failed, TReason}}
            end;
        {error, Reason} ->
            close(Transport, Socket),
            {error, Reason}
    end.

transfer(gen_tcp, Socket, Pid) -> gen_tcp:controlling_process(Socket, Pid);
transfer(ssl, Socket, Pid) -> ssl:controlling_process(Socket, Pid).

peer_host_bin(Host) when is_list(Host)   -> iolist_to_binary(Host);
peer_host_bin(Host) when is_binary(Host) -> Host;
peer_host_bin(Host) when is_tuple(Host)  ->
    iolist_to_binary(inet:ntoa(Host));
peer_host_bin(_) -> undefined.

close(gen_tcp, Sock) -> _ = gen_tcp:close(Sock), ok;
close(ssl, Sock) -> _ = ssl:close(Sock), ok.

merge(Default, Override) ->
    lists:ukeymerge(1,
                    lists:ukeysort(1, Override),
                    lists:ukeysort(1, Default)).
