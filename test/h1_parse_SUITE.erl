%%% @doc Common Test suite for the HTTP/1.1 streaming parser.
-module(h1_parse_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include("h1.hrl").

-export([all/0, groups/0]).
-export([
    parse_simple_get/1,
    parse_get_with_query/1,
    parse_post_content_length/1,
    parse_chunked_body/1,
    parse_chunked_with_trailers/1,
    parse_response_200/1,
    parse_response_1xx_informational/1,
    parse_response_chunked/1,
    parse_head_response/1,
    parse_incremental_bytes/1,
    parse_pipelined_requests/1,
    parse_expect_continue/1,
    parse_upgrade_connect_udp/1,
    parse_reject_conflicting_framing/1,
    parse_too_many_headers/1,
    parse_method_too_long/1,
    parse_uri_too_long/1,
    parse_invalid_method/1,
    parse_invalid_version/1,
    parse_lf_only_line_endings/1,
    parse_obs_fold_header/1,
    parse_chunk_extensions/1,
    parse_response_with_header_whitespace/1,
    parse_request_absolute_form/1,
    %% M-review additions
    parse_rejects_differing_content_length/1,
    parse_rejects_content_length_list_with_mismatch/1,
    parse_accepts_content_length_duplicate_same_value/1,
    parse_rejects_te_on_http_1_0/1,
    parse_rejects_oversized_chunk_size_line/1,
    parse_rejects_forbidden_trailer/1,
    parse_response_close_delimited_body_needs_finish/1,
    parse_response_204_suppresses_body/1,
    parse_response_304_suppresses_body/1,
    parse_response_1xx_suppresses_body/1,
    parse_enforces_max_body_size_identity/1,
    parse_enforces_max_body_size_chunked/1
]).

all() ->
    [
     {group, request},
     {group, response},
     {group, body},
     {group, robustness}
    ].

groups() ->
    [
     {request, [],
      [parse_simple_get, parse_get_with_query, parse_post_content_length,
       parse_request_absolute_form, parse_upgrade_connect_udp,
       parse_expect_continue, parse_lf_only_line_endings,
       parse_obs_fold_header, parse_pipelined_requests]},
     {response, [],
      [parse_response_200, parse_response_1xx_informational,
       parse_response_chunked, parse_head_response,
       parse_response_with_header_whitespace]},
     {body, [],
      [parse_chunked_body, parse_chunked_with_trailers, parse_chunk_extensions,
       parse_incremental_bytes]},
     {robustness, [],
      [parse_reject_conflicting_framing, parse_too_many_headers,
       parse_method_too_long, parse_uri_too_long,
       parse_invalid_method, parse_invalid_version,
       parse_rejects_differing_content_length,
       parse_rejects_content_length_list_with_mismatch,
       parse_accepts_content_length_duplicate_same_value,
       parse_rejects_te_on_http_1_0,
       parse_rejects_oversized_chunk_size_line,
       parse_rejects_forbidden_trailer,
       parse_response_close_delimited_body_needs_finish,
       parse_response_204_suppresses_body,
       parse_response_304_suppresses_body,
       parse_response_1xx_suppresses_body,
       parse_enforces_max_body_size_identity,
       parse_enforces_max_body_size_chunked]}
    ].

%% ----------------------------------------------------------------------------
%% Requests
%% ----------------------------------------------------------------------------

parse_simple_get(_Config) ->
    Bin = <<"GET / HTTP/1.1\r\nHost: example.com\r\n\r\n">>,
    {ok, <<"GET">>, <<"/">>, <<>>, {1, 1}, Headers, Rest} =
        h1_parse:parse_request(Bin),
    ?assertEqual(<<>>, Rest),
    ?assertEqual(<<"example.com">>, proplists:get_value(<<"host">>, Headers)).

parse_get_with_query(_Config) ->
    Bin = <<"GET /path?a=1&b=2 HTTP/1.1\r\nHost: x\r\n\r\n">>,
    {ok, <<"GET">>, <<"/path">>, <<"a=1&b=2">>, {1, 1}, _, <<>>} =
        h1_parse:parse_request(Bin).

parse_post_content_length(_Config) ->
    Bin = <<"POST /p HTTP/1.1\r\nHost: x\r\n",
            "Content-Length: 5\r\n\r\nhello">>,
    {ok, <<"POST">>, <<"/p">>, <<>>, {1, 1}, _Headers, Rest} =
        h1_parse:parse_request(Bin),
    ?assertEqual(<<"hello">>, Rest).

parse_request_absolute_form(_Config) ->
    %% Absolute-form URI (used by proxies and masque per RFC 9298 §3.2).
    Bin = <<"GET https://example.org/.well-known/masque/udp/192.0.2.6/443/ HTTP/1.1\r\n",
            "Host: example.org\r\n",
            "Connection: Upgrade\r\n",
            "Upgrade: connect-udp\r\n",
            "Capsule-Protocol: ?1\r\n\r\n">>,
    {ok, <<"GET">>, Path, <<>>, {1, 1}, _Headers, <<>>} =
        h1_parse:parse_request(Bin),
    ?assertEqual(<<"https://example.org/.well-known/masque/udp/192.0.2.6/443/">>, Path).

parse_upgrade_connect_udp(_Config) ->
    Bin = <<"GET / HTTP/1.1\r\n",
            "Host: ex\r\n",
            "Connection: Upgrade\r\n",
            "Upgrade: connect-udp\r\n\r\n">>,
    P = h1_parse:parser([request]),
    {request, <<"GET">>, <<"/">>, {1, 1}, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    ?assertEqual(<<"upgrade">>, h1_parse:get(P2, connection)),
    ?assertEqual(<<"connect-udp">>, h1_parse:get(P2, upgrade)).

parse_expect_continue(_Config) ->
    Bin = <<"POST /p HTTP/1.1\r\nHost: x\r\n",
            "Expect: 100-continue\r\n",
            "Content-Length: 4\r\n\r\ndata">>,
    P = h1_parse:parser([request]),
    {request, <<"POST">>, _, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    ?assertEqual(<<"100-continue">>, h1_parse:get(P2, expect)).

parse_lf_only_line_endings(_Config) ->
    %% Tolerate LF-only (RFC 9112 §2.2 tolerance).
    Bin = <<"GET / HTTP/1.1\nHost: x\n\n">>,
    {ok, <<"GET">>, <<"/">>, <<>>, {1, 1}, _H, <<>>} =
        h1_parse:parse_request(Bin).

parse_obs_fold_header(_Config) ->
    %% RFC 9112 allows parsers to replace folded whitespace with a single
    %% space; we accept but normalise.
    Bin = <<"GET / HTTP/1.1\r\nHost: x\r\nX-Custom: a\r\n b\r\n\r\n">>,
    {ok, _, _, _, _, Headers, <<>>} = h1_parse:parse_request(Bin),
    ?assertEqual(<<"a b">>, proplists:get_value(<<"x-custom">>, Headers)).

parse_pipelined_requests(_Config) ->
    Bin = <<"GET /a HTTP/1.1\r\nHost: x\r\n\r\n",
            "GET /b HTTP/1.1\r\nHost: x\r\n\r\n">>,
    {ok, <<"GET">>, <<"/a">>, _, _, _, Rest} = h1_parse:parse_request(Bin),
    ?assertEqual(<<"GET /b HTTP/1.1\r\nHost: x\r\n\r\n">>, Rest),
    {ok, <<"GET">>, <<"/b">>, _, _, _, <<>>} = h1_parse:parse_request(Rest).

%% ----------------------------------------------------------------------------
%% Responses
%% ----------------------------------------------------------------------------

parse_response_200(_Config) ->
    Bin = <<"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello">>,
    {ok, {1, 1}, 200, <<"OK">>, Headers, Rest} =
        h1_parse:parse_response(Bin),
    ?assertEqual(<<"5">>, proplists:get_value(<<"content-length">>, Headers)),
    ?assertEqual(<<"hello">>, Rest).

parse_response_1xx_informational(_Config) ->
    Bin = <<"HTTP/1.1 101 Switching Protocols\r\n",
            "Connection: Upgrade\r\n",
            "Upgrade: connect-udp\r\n\r\n">>,
    {ok, {1, 1}, 101, <<"Switching Protocols">>, _H, <<>>} =
        h1_parse:parse_response(Bin).

parse_response_chunked(_Config) ->
    Bin = <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "5\r\nhello\r\n",
            "6\r\n world\r\n",
            "0\r\n\r\n">>,
    P = h1_parse:parser([response]),
    {response, _, 200, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    {Chunks, Rest} = drain_body(P2, []),
    ?assertEqual(<<"hello world">>, iolist_to_binary(Chunks)),
    ?assertEqual(<<>>, Rest).

parse_head_response(_Config) ->
    %% Response to a HEAD request: the parser must not attempt to read a
    %% body even though Content-Length is present. The caller flags this
    %% by constructing the parser with the record's `method' set.
    Bin = <<"HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n">>,
    P = (h1_parse:parser([response]))#h1_parser{method = <<"HEAD">>},
    {response, _, 200, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    ?assertEqual({done, <<>>}, h1_parse:execute(P2)).

parse_response_with_header_whitespace(_Config) ->
    Bin = <<"HTTP/1.1 200 OK\r\nX-Pad:    value with spaces   \r\n\r\n">>,
    {ok, _, 200, _, Headers, <<>>} = h1_parse:parse_response(Bin),
    ?assertEqual(<<"value with spaces">>, proplists:get_value(<<"x-pad">>, Headers)).

%% ----------------------------------------------------------------------------
%% Body decoding
%% ----------------------------------------------------------------------------

parse_chunked_body(_Config) ->
    Bin = <<"POST /p HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n",
            "5\r\nhello\r\n",
            "0\r\n\r\n">>,
    P = h1_parse:parser([request]),
    {request, _, _, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    {Chunks, _} = drain_body(P2, []),
    ?assertEqual(<<"hello">>, iolist_to_binary(Chunks)).

parse_chunked_with_trailers(_Config) ->
    Bin = <<"POST /p HTTP/1.1\r\nHost: x\r\n",
            "Transfer-Encoding: chunked\r\n",
            "Trailer: X-Checksum\r\n\r\n",
            "5\r\nhello\r\n",
            "0\r\n",
            "X-Checksum: abc123\r\n",
            "\r\n">>,
    P = h1_parse:parser([request]),
    {request, _, _, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    {Chunks, Trailers, _} = drain_body_with_trailers(P2, [], []),
    ?assertEqual(<<"hello">>, iolist_to_binary(Chunks)),
    ?assertEqual(<<"abc123">>, proplists:get_value(<<"x-checksum">>, Trailers)).

parse_chunk_extensions(_Config) ->
    Bin = <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "5;ext=1\r\nhello\r\n",
            "0\r\n\r\n">>,
    P = h1_parse:parser([response]),
    {response, _, 200, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    {Chunks, _} = drain_body(P2, []),
    ?assertEqual(<<"hello">>, iolist_to_binary(Chunks)).

parse_incremental_bytes(_Config) ->
    %% Feed bytes one-at-a-time. We should reach a `done' or header-complete
    %% state that captures Host + X-Y exactly.
    Bin = <<"GET /foo HTTP/1.1\r\nHost: a\r\nX-Y: z\r\n\r\n">>,
    Bytes = [<<C>> || <<C>> <= Bin],
    P0 = h1_parse:parser([request]),
    {Headers, Rest} = feed_incrementally(P0, Bytes, undefined, []),
    ?assertEqual(<<"a">>, proplists:get_value(<<"host">>, Headers)),
    ?assertEqual(<<"z">>, proplists:get_value(<<"x-y">>, Headers)),
    ?assertEqual(<<>>, Rest).

feed_incrementally(P, [], _, Acc) ->
    case h1_parse:execute(P) of
        {header, KV, P1} -> feed_incrementally(P1, [], undefined, [KV | Acc]);
        {headers_complete, P1} -> feed_incrementally(P1, [], undefined, Acc);
        {done, Rest} -> {lists:reverse(Acc), Rest};
        {more, _} -> {lists:reverse(Acc), <<>>};
        {more, _, _} -> {lists:reverse(Acc), <<>>}
    end;
feed_incrementally(P, [B | Rest], LastEv, Acc) ->
    case h1_parse:execute(P, B) of
        {more, P1} -> feed_incrementally(P1, Rest, more, Acc);
        {more, P1, _} -> feed_incrementally(P1, Rest, more, Acc);
        {request, _, _, _, P1} -> feed_incrementally(P1, Rest, req, Acc);
        {response, _, _, _, P1} -> feed_incrementally(P1, Rest, resp, Acc);
        {header, KV, P1} -> feed_incrementally(P1, Rest, header, [KV | Acc]);
        {headers_complete, P1} -> feed_incrementally(P1, Rest, hdone, Acc);
        {ok, _, P1} -> feed_incrementally(P1, Rest, body, Acc);
        {trailer, _, P1} -> feed_incrementally(P1, Rest, tr, Acc);
        {done, TailRest} -> {lists:reverse(Acc), TailRest};
        {error, R} -> error({parse_failed, R, LastEv})
    end.

%% ----------------------------------------------------------------------------
%% Robustness
%% ----------------------------------------------------------------------------

parse_reject_conflicting_framing(_Config) ->
    %% RFC 9112 §6.1 — smuggling guard
    Bin = <<"POST / HTTP/1.1\r\nHost: x\r\n",
            "Content-Length: 5\r\n",
            "Transfer-Encoding: chunked\r\n\r\n">>,
    ?assertEqual({error, conflicting_framing}, h1_parse:parse_request(Bin)).

parse_too_many_headers(_Config) ->
    HeaderBins = [<<"X-", (integer_to_binary(N))/binary, ": v\r\n">> || N <- lists:seq(1, 200)],
    Head = <<"GET / HTTP/1.1\r\n">>,
    End = <<"\r\n">>,
    Bin = iolist_to_binary([Head, HeaderBins, End]),
    ?assertEqual({error, too_many_headers},
                 h1_parse:parse_request(Bin, #{max_headers => 10})).

parse_method_too_long(_Config) ->
    Bin = iolist_to_binary([binary:copy(<<"A">>, 100), " / HTTP/1.1\r\nHost: x\r\n\r\n"]),
    ?assertEqual({error, method_too_long}, h1_parse:parse_request(Bin)).

parse_uri_too_long(_Config) ->
    Bin = iolist_to_binary([<<"GET /">>, binary:copy(<<"x">>, 9000), <<" HTTP/1.1\r\nHost: x\r\n\r\n">>]),
    ?assertEqual({error, uri_too_long}, h1_parse:parse_request(Bin)).

parse_invalid_method(_Config) ->
    Bin = <<"g\x00t / HTTP/1.1\r\n\r\n">>,
    case h1_parse:parse_request(Bin) of
        {error, _} -> ok;
        Other -> ct:fail({expected_error, Other})
    end.

parse_invalid_version(_Config) ->
    Bin = <<"GET / HTTP/9.Z\r\n\r\n">>,
    ?assertEqual({error, bad_request}, h1_parse:parse_request(Bin)).

%% ----------------------------------------------------------------------------
%% Review batch: smuggling, DoS, body-framing edge cases
%% ----------------------------------------------------------------------------

parse_rejects_differing_content_length(_Config) ->
    Bin = <<"POST /p HTTP/1.1\r\nHost: x\r\n",
            "Content-Length: 5\r\n",
            "Content-Length: 7\r\n\r\nhello">>,
    ?assertEqual({error, conflicting_content_length},
                 h1_parse:parse_request(Bin)).

parse_rejects_content_length_list_with_mismatch(_Config) ->
    Bin = <<"POST /p HTTP/1.1\r\nHost: x\r\n",
            "Content-Length: 5, 7\r\n\r\nhello">>,
    ?assertEqual({error, conflicting_content_length},
                 h1_parse:parse_request(Bin)).

parse_accepts_content_length_duplicate_same_value(_Config) ->
    Bin = <<"POST /p HTTP/1.1\r\nHost: x\r\n",
            "Content-Length: 5\r\n",
            "Content-Length: 5\r\n\r\nhello">>,
    {ok, <<"POST">>, _, _, _, _, Rest} = h1_parse:parse_request(Bin),
    ?assertEqual(<<"hello">>, Rest).

parse_rejects_te_on_http_1_0(_Config) ->
    Bin = <<"POST /p HTTP/1.0\r\nHost: x\r\n",
            "Transfer-Encoding: chunked\r\n\r\n",
            "0\r\n\r\n">>,
    ?assertEqual({error, te_on_http_1_0},
                 h1_parse:parse_request(Bin)).

parse_rejects_oversized_chunk_size_line(_Config) ->
    HugeHex = binary:copy(<<"A">>, 100),
    Bin = <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            HugeHex/binary, "\r\n">>,
    P = h1_parse:parser([response]),
    {response, _, _, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    ?assertMatch({error, chunk_size_too_long}, h1_parse:execute(P2)).

parse_rejects_forbidden_trailer(_Config) ->
    Bin = <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n",
            "Trailer: Content-Length\r\n\r\n",
            "3\r\nfoo\r\n",
            "0\r\n",
            "Content-Length: 0\r\n",
            "\r\n">>,
    P = h1_parse:parser([response]),
    {response, _, _, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    {Result, _} = drain_until_end(h1_parse:execute(P2), []),
    ?assertEqual({error, forbidden_trailer}, Result).

parse_response_close_delimited_body_needs_finish(_Config) ->
    %% No Content-Length, no Transfer-Encoding → body extends to EOF.
    Bin = <<"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n",
            "streaming bytes">>,
    P = h1_parse:parser([response]),
    {response, _, _, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    %% First read yields the available chunk.
    {ok, <<"streaming bytes">>, P3} = h1_parse:execute(P2),
    %% Without `finish/1`, parser stays open.
    ?assertMatch({more, _, _}, h1_parse:execute(P3, <<>>)),
    %% Driver calls finish after socket close to terminate the body.
    ?assertEqual({done, <<>>}, h1_parse:finish(P3)).

parse_response_204_suppresses_body(_Config) ->
    %% 204 MUST NOT have a body even if Content-Length is present.
    Bin = <<"HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\nhello">>,
    P = h1_parse:parser([response]),
    {response, _, 204, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    ?assertEqual({done, <<"hello">>}, h1_parse:execute(P2)).

parse_response_304_suppresses_body(_Config) ->
    Bin = <<"HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\nhello">>,
    P = h1_parse:parser([response]),
    {response, _, 304, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    ?assertEqual({done, <<"hello">>}, h1_parse:execute(P2)).

parse_response_1xx_suppresses_body(_Config) ->
    Bin = <<"HTTP/1.1 102 Processing\r\n\r\n">>,
    P = h1_parse:parser([response]),
    {response, _, 102, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    ?assertEqual({done, <<>>}, h1_parse:execute(P2)).

parse_enforces_max_body_size_identity(_Config) ->
    Bin = <<"HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n",
            "XXXXXXXXXXXXXXXXXXXX">>,
    P = h1_parse:parser([response, {max_body_size, 10}]),
    {response, _, _, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    ?assertMatch({error, body_too_large}, h1_parse:execute(P2)).

parse_enforces_max_body_size_chunked(_Config) ->
    Bin = <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
            "5\r\nhello\r\n",
            "6\r\n world\r\n",
            "0\r\n\r\n">>,
    P = h1_parse:parser([response, {max_body_size, 5}]),
    {response, _, _, _, P1} = h1_parse:execute(P, Bin),
    P2 = drain_headers(P1),
    %% First 5-byte chunk is OK; second chunk pushes total past 5.
    {ok, <<"hello">>, P3} = h1_parse:execute(P2),
    ?assertMatch({error, body_too_large}, h1_parse:execute(P3)).

drain_until_end({error, _} = E, Acc) -> {E, lists:reverse(Acc)};
drain_until_end({done, _} = D, Acc)  -> {D, lists:reverse(Acc)};
drain_until_end({trailer, KV, P}, Acc) -> drain_until_end(h1_parse:execute(P), [KV | Acc]);
drain_until_end({ok, _, P}, Acc)       -> drain_until_end(h1_parse:execute(P), Acc);
drain_until_end({headers_complete, P}, Acc) -> drain_until_end(h1_parse:execute(P), Acc);
drain_until_end({more, _, _}, Acc)     -> {more, lists:reverse(Acc)};
drain_until_end(Other, Acc)            -> {Other, lists:reverse(Acc)}.

%% ----------------------------------------------------------------------------
%% Helpers
%% ----------------------------------------------------------------------------

drain_headers(P) ->
    case h1_parse:execute(P) of
        {header, _, P1} -> drain_headers(P1);
        {headers_complete, P1} -> P1;
        {error, R} -> error({drain_headers, R})
    end.

drain_body(P, Acc) ->
    case h1_parse:execute(P) of
        {ok, Chunk, P1} -> drain_body(P1, [Chunk | Acc]);
        {more, P1, _} -> drain_body(P1, Acc);
        {more, _} -> {lists:reverse(Acc), <<>>};
        {done, Rest} -> {lists:reverse(Acc), Rest};
        {trailer, _, P1} -> drain_body(P1, Acc);
        {error, R} -> error({drain_body, R})
    end.

drain_body_with_trailers(P, Body, Trailers) ->
    case h1_parse:execute(P) of
        {ok, Chunk, P1} -> drain_body_with_trailers(P1, [Chunk | Body], Trailers);
        {trailer, KV, P1} -> drain_body_with_trailers(P1, Body, [KV | Trailers]);
        {done, Rest} -> {lists:reverse(Body), lists:reverse(Trailers), Rest};
        {more, P1, _} -> drain_body_with_trailers(P1, Body, Trailers);
        {more, _} -> {lists:reverse(Body), lists:reverse(Trailers), <<>>};
        {error, R} -> error({drain_body, R})
    end.
