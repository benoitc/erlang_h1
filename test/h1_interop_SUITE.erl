%%% @doc Interoperability tests: our server against curl, our client
%%% against python3 http.server and nginx. Each case probes for its
%%% external tool via `os:find_executable/1' and is skipped when the
%%% binary is absent so CI without the tool stays green.
-module(h1_interop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([
    curl_get/1,
    curl_post/1,
    curl_head/1,
    curl_chunked/1,
    our_client_to_python/1,
    our_client_to_nginx/1
]).

all() ->
    [curl_get, curl_post, curl_head, curl_chunked,
     our_client_to_python, our_client_to_nginx].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(h1),
    Config.

end_per_suite(_Config) ->
    application:stop(h1),
    ok.

init_per_testcase(TC, Config) ->
    process_flag(trap_exit, true),
    case required_tool(TC) of
        none   -> Config;
        curl   -> probe("curl", Config);
        docker -> probe_docker(Config)
    end.

end_per_testcase(_TC, Config) ->
    case ?config(server_ref, Config) of
        undefined -> ok;
        Ref -> catch h1:stop_server(Ref)
    end,
    case ?config(docker_container, Config) of
        undefined -> ok;
        Cid -> _ = os:cmd("docker stop " ++ Cid ++ " >/dev/null 2>&1"), ok
    end,
    ok.

%% `curl` runs locally because it's just a client we drive against our
%% server. Anything that needs to *be* the peer (nginx, python
%% http.server) is launched in a short-lived Docker container so the
%% host stays clean and the test environment matches what runs in CI.
required_tool(curl_get)              -> curl;
required_tool(curl_post)             -> curl;
required_tool(curl_head)             -> curl;
required_tool(curl_chunked)          -> curl;
required_tool(our_client_to_python)  -> docker;
required_tool(our_client_to_nginx)   -> docker;
required_tool(_)                     -> none.

probe(Bin, Config) ->
    case os:find_executable(Bin) of
        false -> {skip, {missing, Bin}};
        _     -> Config
    end.

probe_docker(Config) ->
    case os:find_executable("docker") of
        false -> {skip, {missing, "docker"}};
        _ ->
            %% Confirm the daemon is reachable, not just the CLI.
            case os:cmd("docker info --format '{{.ServerVersion}}' 2>/dev/null") of
                "" ++ _ = S when S =:= ""; S =:= "\n" ->
                    {skip, {docker, daemon_unreachable}};
                _  -> Config
            end
    end.

%% ----------------------------------------------------------------------------
%% Handlers
%% ----------------------------------------------------------------------------

simple_get_handler(Conn, StreamId, _M, _P, _Hs) ->
    Body = <<"hello from h1">>,
    ok = h1:send_response(Conn, StreamId, 200,
        [{<<"content-length">>, integer_to_binary(byte_size(Body))},
         {<<"content-type">>, <<"text/plain">>}]),
    ok = h1:send_data(Conn, StreamId, Body, true).

echo_post_handler(Conn, StreamId, _M, _P, Headers) ->
    Len = case proplists:get_value(<<"content-length">>, Headers) of
        undefined -> 0;
        V -> binary_to_integer(V)
    end,
    Body = drain_body(StreamId, Len, <<>>),
    ok = h1:send_response(Conn, StreamId, 200,
        [{<<"content-length">>, integer_to_binary(byte_size(Body))}]),
    ok = h1:send_data(Conn, StreamId, Body, true).

chunked_handler(Conn, StreamId, _M, _P, _H) ->
    ok = h1:send_response(Conn, StreamId, 200,
        [{<<"transfer-encoding">>, <<"chunked">>}]),
    ok = h1:send_data(Conn, StreamId, <<"one-">>,  false),
    ok = h1:send_data(Conn, StreamId, <<"two-">>,  false),
    ok = h1:send_data(Conn, StreamId, <<"three">>, true).

drain_body(_StreamId, 0, Acc) -> Acc;
drain_body(StreamId, _Remaining, Acc) ->
    receive
        {h1_stream, StreamId, {data, Chunk, true}} ->
            <<Acc/binary, Chunk/binary>>;
        {h1_stream, StreamId, {data, Chunk, false}} ->
            drain_body(StreamId, 0, <<Acc/binary, Chunk/binary>>);
        {h1_stream, StreamId, _} ->
            Acc
    after 5000 -> Acc
    end.

%% ----------------------------------------------------------------------------
%% Our server, tested with curl
%% ----------------------------------------------------------------------------

curl_get(Config0) ->
    Config = start_tcp_server(fun simple_get_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {Status, Out} = curl(["-s", "-w", "%{http_code}\n",
                          url(Port, "/")]),
    ?assertEqual(0, Status),
    {Body, Code} = split_curl(Out),
    ?assertEqual(<<"200">>, Code),
    ?assertEqual(<<"hello from h1">>, Body),
    ok.

curl_post(Config0) ->
    Config = start_tcp_server(fun echo_post_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    Payload = "the-body-bytes",
    {Status, Out} = curl(["-s", "-w", "%{http_code}\n",
                          "-d", Payload, url(Port, "/echo")]),
    ?assertEqual(0, Status),
    {Body, Code} = split_curl(Out),
    ?assertEqual(<<"200">>, Code),
    ?assertEqual(list_to_binary(Payload), Body),
    ok.

curl_head(Config0) ->
    Config = start_tcp_server(fun simple_get_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    {Status, Out} = curl(["-s", "-I", url(Port, "/")]),
    ?assertEqual(0, Status),
    ?assertMatch({match, _}, re:run(Out, <<"HTTP/1\\.1 200">>)),
    ?assertMatch({match, _}, re:run(Out, <<"(?i)content-length: 13">>)),
    ok.

curl_chunked(Config0) ->
    Config = start_tcp_server(fun chunked_handler/5, Config0),
    Port = h1:server_port(?config(server_ref, Config)),
    %% --raw keeps the chunks so we can verify they actually wire up,
    %% but a default curl run just returns the reassembled body.
    {Status, Out} = curl(["-s", url(Port, "/")]),
    ?assertEqual(0, Status),
    ?assertEqual(<<"one-two-three">>, iolist_to_binary(Out)),
    ok.

%% ----------------------------------------------------------------------------
%% Our client, against python3 http.server
%% ----------------------------------------------------------------------------

our_client_to_python(Config0) ->
    Dir = filename:join(?config(priv_dir, Config0), "www"),
    ok = filelib:ensure_dir(filename:join(Dir, ".")),
    ok = file:write_file(filename:join(Dir, "hello.txt"),
                         <<"from python">>),
    {Cid, Port} = docker_run(
        ["-v", Dir ++ ":/srv:ro", "-w", "/srv",
         "-p", "127.0.0.1::8000",
         "python:3-alpine",
         "python3", "-m", "http.server", "8000", "--bind", "0.0.0.0"],
        8000),
    Config = [{docker_container, Cid} | Config0],
    ok = wait_ready("127.0.0.1", Port, 100),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/hello.txt">>,
                          [{<<"host">>, <<"127.0.0.1">>}]),
    {Status, _Hs, Body} = collect_response(Conn, Id),
    ?assertEqual(200, Status),
    ?assertEqual(<<"from python">>, Body),
    h1:close(Conn),
    {save_config, Config}.

%% ----------------------------------------------------------------------------
%% Our client, against nginx
%% ----------------------------------------------------------------------------

our_client_to_nginx(Config0) ->
    Html = filename:join(?config(priv_dir, Config0), "nginx-html"),
    ok = filelib:ensure_dir(filename:join(Html, ".")),
    ok = file:write_file(filename:join(Html, "index.html"),
                         <<"hello from nginx\n">>),
    {Cid, Port} = docker_run(
        ["-v", Html ++ ":/usr/share/nginx/html:ro",
         "-p", "127.0.0.1::80",
         "nginx:alpine"],
        80),
    Config = [{docker_container, Cid} | Config0],
    ok = wait_ready("127.0.0.1", Port, 100),
    {ok, Conn} = h1:connect("127.0.0.1", Port, #{transport => tcp}),
    {ok, Id} = h1:request(Conn, <<"GET">>, <<"/">>,
                          [{<<"host">>, <<"127.0.0.1">>}]),
    {Status, _Hs, Body} = collect_response(Conn, Id),
    ?assertEqual(200, Status),
    ?assertEqual(<<"hello from nginx\n">>, Body),
    h1:close(Conn),
    {save_config, Config}.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

start_tcp_server(Handler, Config) ->
    Opts = #{transport => tcp, handler => Handler, acceptors => 1},
    {ok, Ref} = h1:start_server(0, Opts),
    [{server_ref, Ref} | Config].

url(Port, Path) ->
    "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path.

curl(Args) ->
    Exe = os:find_executable("curl"),
    Port = erlang:open_port(
        {spawn_executable, Exe},
        [{args, Args}, exit_status, stderr_to_stdout, binary]),
    collect_port(Port, <<>>).

collect_port(Port, Acc) ->
    receive
        {Port, {data, Bin}} -> collect_port(Port, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc}
    after 10000 ->
        erlang:port_close(Port),
        {timeout, Acc}
    end.

split_curl(Out) ->
    %% "Body...\n200" — but curl's -w appends without a leading \n, so
    %% the 3-digit status is the tail of the binary.
    Sz = byte_size(Out),
    Body = binary:part(Out, 0, Sz - 4),  %% strip "NNN\n"
    Code = binary:part(Out, Sz - 4, 3),
    {Body, Code}.

%% Start an auto-removing container, publishing the given container port
%% to a random host port on 127.0.0.1. Returns the container id and the
%% host-side port number. The caller is responsible for `docker stop'
%% in `end_per_testcase'. `open_port' with `spawn_executable' skips the
%% shell so argument quoting is a non-issue.
docker_run(ExtraArgs, ContainerPort) ->
    Args = ["run", "-d", "--rm"] ++ ExtraArgs,
    {Out, 0} = run_docker(Args),
    Cid = string:trim(Out),
    case Cid of
        [] -> ct:fail({docker_run_failed, Args, Out});
        _  -> {Cid, docker_host_port(Cid, ContainerPort)}
    end.

docker_host_port(Cid, ContainerPort) ->
    {Out, 0} = run_docker(["port", Cid,
                           integer_to_list(ContainerPort) ++ "/tcp"]),
    %% "docker port" prints "0.0.0.0:54321\n127.0.0.1:54321\n" or
    %% similar — take the last colon-separated token of the first line.
    Line = hd(string:split(string:trim(Out), "\n")),
    [_, PortStr] = string:split(Line, ":", trailing),
    list_to_integer(string:trim(PortStr)).

run_docker(Args) ->
    Exe = os:find_executable("docker"),
    P = erlang:open_port({spawn_executable, Exe},
                         [{args, Args}, exit_status, stderr_to_stdout,
                          binary]),
    collect_port_output(P, <<>>).

collect_port_output(Port, Acc) ->
    receive
        {Port, {data, Bin}} ->
            collect_port_output(Port, <<Acc/binary, Bin/binary>>);
        {Port, {exit_status, Code}} ->
            {binary_to_list(Acc), Code}
    after 30000 ->
        catch erlang:port_close(Port),
        {binary_to_list(Acc), timeout}
    end.

wait_ready(_Host, _Port, 0) -> {error, not_ready};
wait_ready(Host, Port, N) ->
    %% Docker publishes the port as soon as the container starts, but
    %% the process inside may not be serving yet. Probe with an actual
    %% HTTP HEAD-ish request and wait for bytes back.
    case gen_tcp:connect(Host, Port, [binary, {active, false}], 200) of
        {ok, S} ->
            gen_tcp:send(S, <<"GET / HTTP/1.0\r\nHost: probe\r\n\r\n">>),
            R = gen_tcp:recv(S, 0, 200),
            gen_tcp:close(S),
            case R of
                {ok, _} -> ok;
                _ ->
                    timer:sleep(100),
                    wait_ready(Host, Port, N - 1)
            end;
        {error, _} ->
            timer:sleep(100),
            wait_ready(Host, Port, N - 1)
    end.

collect_response(Conn, Id) ->
    collect_response(Conn, Id, undefined, [], <<>>).

collect_response(Conn, Id, Status, Hs, Body) ->
    receive
        {h1, Conn, connected} ->
            collect_response(Conn, Id, Status, Hs, Body);
        {h1, Conn, {response, Id, S, H}} ->
            collect_response(Conn, Id, S, H, Body);
        {h1, Conn, {informational, Id, _, _}} ->
            collect_response(Conn, Id, Status, Hs, Body);
        {h1, Conn, {data, Id, D, false}} ->
            collect_response(Conn, Id, Status, Hs, <<Body/binary, D/binary>>);
        {h1, Conn, {data, Id, D, true}} ->
            {Status, Hs, <<Body/binary, D/binary>>};
        {h1, Conn, {trailers, Id, _}} ->
            {Status, Hs, Body};
        {h1, Conn, {closed, _}} ->
            {Status, Hs, Body}
    after 5000 ->
        ct:fail({response_timeout, Status, Hs, Body})
    end.

