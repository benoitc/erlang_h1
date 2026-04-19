%%% @doc Encoder round-trip tests: everything we emit must parse back.
-module(h1_message_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("h1.hrl").

-export([all/0]).
-export([
    encode_request_line/1,
    encode_status_line/1,
    encode_status_line_custom_reason/1,
    encode_request_roundtrip/1,
    encode_response_roundtrip/1,
    encode_chunked_roundtrip/1,
    encode_trailers_roundtrip/1,
    choose_framing_known_body/1,
    choose_framing_chunked/1,
    choose_framing_no_body/1,
    reject_header_injection/1,
    encode_rejects_header_name_with_crlf/1,
    encode_rejects_method_with_crlf/1,
    encode_rejects_path_with_crlf/1,
    encode_rejects_reason_with_control_chars/1,
    status_text_coverage/1
]).

all() ->
    [encode_request_line, encode_status_line, encode_status_line_custom_reason,
     encode_request_roundtrip, encode_response_roundtrip,
     encode_chunked_roundtrip, encode_trailers_roundtrip,
     choose_framing_known_body, choose_framing_chunked, choose_framing_no_body,
     reject_header_injection,
     encode_rejects_header_name_with_crlf,
     encode_rejects_method_with_crlf,
     encode_rejects_path_with_crlf,
     encode_rejects_reason_with_control_chars,
     status_text_coverage].

encode_request_line(_Config) ->
    ?assertEqual(<<"GET / HTTP/1.1\r\n">>,
                 iolist_to_binary(h1_message:request_line(<<"GET">>, <<"/">>, ?HTTP_1_1))),
    ?assertEqual(<<"POST /p?q=1 HTTP/1.1\r\n">>,
                 iolist_to_binary(h1_message:request_line(<<"POST">>, <<"/p">>, <<"q=1">>, ?HTTP_1_1))).

encode_status_line(_Config) ->
    ?assertEqual(<<"HTTP/1.1 200 OK\r\n">>,
                 iolist_to_binary(h1_message:status_line(200, ?HTTP_1_1))),
    ?assertEqual(<<"HTTP/1.1 101 Switching Protocols\r\n">>,
                 iolist_to_binary(h1_message:status_line(101, ?HTTP_1_1))).

encode_status_line_custom_reason(_Config) ->
    ?assertEqual(<<"HTTP/1.1 499 Client Closed Request\r\n">>,
                 iolist_to_binary(h1_message:status_line(499, <<"Client Closed Request">>, ?HTTP_1_1))).

encode_request_roundtrip(_Config) ->
    Headers = [{<<"host">>, <<"example.com">>},
               {<<"user-agent">>, <<"h1-tests/1.0">>}],
    Body = <<"hello">>,
    Bin = iolist_to_binary(
            h1_message:encode_request(<<"POST">>, <<"/p">>, Headers, Body)),
    {ok, <<"POST">>, <<"/p">>, <<>>, {1, 1}, Parsed, <<"hello">>} =
        h1_parse:parse_request(Bin),
    ?assertEqual(<<"example.com">>, proplists:get_value(<<"host">>, Parsed)),
    ?assertEqual(<<"5">>, proplists:get_value(<<"content-length">>, Parsed)).

encode_response_roundtrip(_Config) ->
    Headers = [{<<"content-type">>, <<"text/plain">>}],
    Body = <<"hello world">>,
    Bin = iolist_to_binary(h1_message:encode_response(200, Headers, Body)),
    {ok, {1, 1}, 200, <<"OK">>, Parsed, Rest} = h1_parse:parse_response(Bin),
    ?assertEqual(<<"11">>, proplists:get_value(<<"content-length">>, Parsed)),
    ?assertEqual(Body, Rest).

encode_chunked_roundtrip(_Config) ->
    %% Manually stream two chunks + final.
    Head = iolist_to_binary([
        h1_message:status_line(200, ?HTTP_1_1),
        h1_message:headers([{<<"transfer-encoding">>, <<"chunked">>}]),
        <<"\r\n">>]),
    Bin = iolist_to_binary([Head,
                            h1_message:encode_chunk(<<"hello">>),
                            h1_message:encode_chunk(<<" world">>),
                            h1_message:encode_last_chunk()]),
    P = h1_parse:parser([response]),
    {response, _, 200, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    {Chunks, _} = drain_body(P2, []),
    ?assertEqual(<<"hello world">>, iolist_to_binary(Chunks)).

encode_trailers_roundtrip(_Config) ->
    Head = iolist_to_binary([
        h1_message:status_line(200, ?HTTP_1_1),
        h1_message:headers([{<<"transfer-encoding">>, <<"chunked">>},
                            {<<"trailer">>, <<"x-checksum">>}]),
        <<"\r\n">>]),
    Bin = iolist_to_binary([Head,
                            h1_message:encode_chunk(<<"hello">>),
                            h1_message:encode_last_chunk([{<<"x-checksum">>, <<"abc">>}])]),
    P = h1_parse:parser([response]),
    {response, _, 200, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    {Chunks, Trailers, _} = drain_body_with_trailers(P2, [], []),
    ?assertEqual(<<"hello">>, iolist_to_binary(Chunks)),
    ?assertEqual(<<"abc">>, proplists:get_value(<<"x-checksum">>, Trailers)).

choose_framing_known_body(_Config) ->
    {content_length, 5, Headers} =
        h1_message:choose_framing(<<"hello">>, [{<<"host">>, <<"x">>}]),
    ?assertEqual(<<"5">>, proplists:get_value(<<"content-length">>, Headers)).

choose_framing_chunked(_Config) ->
    {chunked, Headers} =
        h1_message:choose_framing(chunked, [{<<"content-length">>, <<"9">>}]),
    ?assertEqual(undefined, proplists:get_value(<<"content-length">>, Headers)),
    ?assertEqual(<<"chunked">>, proplists:get_value(<<"transfer-encoding">>, Headers)).

choose_framing_no_body(_Config) ->
    {no_body, Headers} =
        h1_message:choose_framing(no_body, [{<<"content-length">>, <<"5">>},
                                            {<<"x">>, <<"y">>}]),
    ?assertEqual(undefined, proplists:get_value(<<"content-length">>, Headers)),
    ?assertEqual(<<"y">>, proplists:get_value(<<"x">>, Headers)).

reject_header_injection(_Config) ->
    %% Bare CR or LF in a header value must not be silently included.
    Evil = [{<<"x-evil">>, <<"a\r\nX-Injected: yes">>}],
    ?assertError({invalid_header_value, _}, h1_message:headers(Evil)).

encode_rejects_header_name_with_crlf(_Config) ->
    Evil = [{<<"X-Evil\r\nX-Injected">>, <<"v">>}],
    ?assertError({invalid_header_name, _}, h1_message:headers(Evil)).

encode_rejects_method_with_crlf(_Config) ->
    ?assertError({invalid_method, _},
                 h1_message:request_line(<<"GET\r\n">>, <<"/">>, ?HTTP_1_1)).

encode_rejects_path_with_crlf(_Config) ->
    ?assertError({invalid_path, _},
                 h1_message:request_line(<<"GET">>, <<"/\r\ninjected">>, ?HTTP_1_1)).

encode_rejects_reason_with_control_chars(_Config) ->
    ?assertError({invalid_reason_phrase, _},
                 h1_message:status_line(500, <<"Oops\x01Bad">>, ?HTTP_1_1)).

status_text_coverage(_Config) ->
    %% Sample a handful including the 101 entry used by Upgrade.
    ?assertEqual(<<"OK">>, h1_message:status_text(200)),
    ?assertEqual(<<"Switching Protocols">>, h1_message:status_text(101)),
    ?assertEqual(<<"Not Found">>, h1_message:status_text(404)),
    ?assertEqual(<<"Upgrade Required">>, h1_message:status_text(426)),
    ?assertEqual(<<"Unknown">>, h1_message:status_text(999)).

%% helpers
drain_headers(P) ->
    case h1_parse:execute(P) of
        {header, _, P1} -> drain_headers(P1);
        {headers_complete, P1} -> P1
    end.

drain_body(P, Acc) ->
    case h1_parse:execute(P) of
        {ok, C, P1} -> drain_body(P1, [C | Acc]);
        {more, _, _} -> {lists:reverse(Acc), <<>>};
        {more, _} -> {lists:reverse(Acc), <<>>};
        {done, Rest} -> {lists:reverse(Acc), Rest};
        {trailer, _, P1} -> drain_body(P1, Acc)
    end.

drain_body_with_trailers(P, B, T) ->
    case h1_parse:execute(P) of
        {ok, C, P1} -> drain_body_with_trailers(P1, [C | B], T);
        {trailer, KV, P1} -> drain_body_with_trailers(P1, B, [KV | T]);
        {done, Rest} -> {lists:reverse(B), lists:reverse(T), Rest}
    end.
