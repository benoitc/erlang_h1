%%% -*- erlang -*-
%%%
%%% Streaming pure-Erlang HTTP/1.1 parser.
%%%
%%% Derived from hackney_http.erl (Apache 2.0, © 2011-2012 Loïc Hoguin,
%%% © 2013-2015 Benoit Chesneau) and livery_h1_parse_erl.erl (© enki-multimedia).
%%% Licensed under Apache 2.0 to match both upstreams.
%%%
%%% Dual-mode: auto-detects request vs response, or caller can force either.
%%%
%%% Usage
%%% -----
%%%
%%%   P0 = h1_parse_erl:parser([request]),
%%%   case h1_parse_erl:execute(P0, Bin) of
%%%       {request, Method, URI, Version, P1} -> ...;
%%%       {response, Version, Status, Reason, P1} -> ...;
%%%       {header, {Name, Value}, P1} -> ...;
%%%       {headers_complete, P1} -> ...;
%%%       {ok, Chunk, P1} -> ...;            %% body chunk (content-length or chunked)
%%%       {trailer, {Name, Value}, P1} -> ...;
%%%       {more, P1} -> ...;                 %% line/header phase needs more bytes
%%%       {more, P1, Buffer} -> ...;         %% body phase needs more bytes
%%%       {done, Rest} -> ...;               %% message complete; Rest may seed next one
%%%       {error, Reason} -> ...
%%%   end.
%%%
%%% After a header event, call execute/1 to continue without feeding new
%%% bytes. After {more, _} or {more, _, _} feed the next chunk via
%%% execute/2. After {done, Rest} create a fresh parser for the next
%%% message in the pipeline, seeded with Rest.
-module(h1_parse_erl).

-export([parser/0, parser/1]).
-export([execute/1, execute/2]).
-export([get/2]).

%% Stateless convenience wrappers (livery-style).
-export([parse_request/1, parse_request/2]).
-export([parse_response/1, parse_response/2]).
-export([parse_chunk/1, parse_chunk/2]).
-export([parse_trailers/1]).

%% Small bstr helpers exposed for h1_message and tests.
-export([to_lower/1, trim/1, to_int/1]).

-include("h1.hrl").

-type parser() :: #h1_parser{}.
-type http_version() :: {non_neg_integer(), non_neg_integer()}.
-type status() :: 100..599.
-type http_reason() :: binary().
-type http_method() :: binary().
-type uri() :: binary().

-type parser_option() :: request | response | auto
                       | {max_line_length, pos_integer()}
                       | {max_empty_lines, non_neg_integer()}
                       | {max_header_name_size, pos_integer()}
                       | {max_header_value_size, pos_integer()}
                       | {max_headers, pos_integer()}.

-type body_result() :: {ok, binary(), parser()}
                     | {trailer, {binary(), binary()}, parser()}
                     | {more, parser()}
                     | {more, parser(), binary()}
                     | {done, binary()}
                     | {error, term()}.

-type header_result() :: {headers_complete, parser()}
                       | {header, {binary(), binary()}, parser()}.

-type parser_result() ::
        {response, http_version(), status(), http_reason(), parser()}
      | {request, http_method(), uri(), http_version(), parser()}
      | {more, parser()}
      | header_result()
      | body_result()
      | {error, term()}.

-export_type([parser/0, parser_result/0, parser_option/0,
              http_version/0, status/0, http_method/0, uri/0]).

%% ----------------------------------------------------------------------------
%% Construction
%% ----------------------------------------------------------------------------

-spec parser() -> parser().
parser() ->
    parser([]).

-spec parser([parser_option()]) -> parser().
parser(Options) ->
    apply_options(Options, #h1_parser{}).

apply_options([], St) -> St;
apply_options([auto | R], St) -> apply_options(R, St#h1_parser{type = auto});
apply_options([request | R], St) -> apply_options(R, St#h1_parser{type = request});
apply_options([response | R], St) -> apply_options(R, St#h1_parser{type = response});
apply_options([{max_line_length, N} | R], St) when is_integer(N), N > 0 ->
    apply_options(R, St#h1_parser{max_line_length = N});
apply_options([{max_empty_lines, N} | R], St) when is_integer(N), N >= 0 ->
    apply_options(R, St#h1_parser{max_empty_lines = N});
apply_options([{max_header_name_size, N} | R], St) when is_integer(N), N > 0 ->
    apply_options(R, St#h1_parser{max_header_name_size = N});
apply_options([{max_header_value_size, N} | R], St) when is_integer(N), N > 0 ->
    apply_options(R, St#h1_parser{max_header_value_size = N});
apply_options([{max_headers, N} | R], St) when is_integer(N), N > 0 ->
    apply_options(R, St#h1_parser{max_headers = N});
apply_options([_ | R], St) ->
    apply_options(R, St).

%% ----------------------------------------------------------------------------
%% Introspection
%% ----------------------------------------------------------------------------

-spec get(parser(), atom() | [atom()]) -> any().
get(P, Props) when is_list(Props) -> [get_prop(X, P) || X <- Props];
get(P, Prop) -> get_prop(Prop, P).

get_prop(buffer, #h1_parser{buffer = B}) -> B;
get_prop(state, #h1_parser{state = S}) -> S;
get_prop(version, #h1_parser{version = V}) -> V;
get_prop(method, #h1_parser{method = M}) -> M;
get_prop(transfer_encoding, #h1_parser{te = TE}) -> TE;
get_prop(content_length, #h1_parser{clen = C}) -> C;
get_prop(connection, #h1_parser{connection = C}) -> C;
get_prop(content_type, #h1_parser{ctype = C}) -> C;
get_prop(location, #h1_parser{location = L}) -> L;
get_prop(content_encoding, #h1_parser{content_encoding = C}) -> C;
get_prop(upgrade, #h1_parser{upgrade = U}) -> U;
get_prop(expect, #h1_parser{expect = E}) -> E;
get_prop(headers, #h1_parser{partial_headers = H}) -> lists:reverse(H).

%% ----------------------------------------------------------------------------
%% Streaming API
%% ----------------------------------------------------------------------------

-spec execute(parser()) -> parser_result().
execute(St) -> execute(St, <<>>).

-spec execute(parser(), binary()) -> parser_result().
execute(#h1_parser{state = State, buffer = Buf} = St, Bin) ->
    NBuf = <<Buf/binary, Bin/binary>>,
    St1 = St#h1_parser{buffer = NBuf},
    case State of
        done           -> {done, NBuf};
        on_first_line  -> parse_first_line(NBuf, St1, 0);
        on_header      -> parse_header_step(St1);
        on_body        -> parse_body(St1);
        on_trailers    -> parse_trailer_step(St1);
        on_junk        -> skip_junk(St1)
    end.

%% ----------------------------------------------------------------------------
%% First line
%% ----------------------------------------------------------------------------

%% Skip leading bare LF empty lines (RFC 9112 §2.2 tolerance).
parse_first_line(<<$\n, Rest/binary>>,
                 #h1_parser{empty_lines = E0} = St, _Empty) ->
    parse_first_line(Rest, St#h1_parser{buffer = Rest, empty_lines = E0 + 1}, E0 + 1);
parse_first_line(_Buf, #h1_parser{max_empty_lines = Max}, E) when E > Max ->
    {error, bad_request};
parse_first_line(Buf, #h1_parser{max_line_length = Max} = St, _Empty) ->
    case match_eol(Buf, 0) of
        nomatch when byte_size(Buf) > Max ->
            {error, line_too_long};
        nomatch ->
            {more, St};
        1 ->
            %% bare \r\n — empty line, advance and keep waiting.
            <<_:16, Rest/binary>> = Buf,
            parse_first_line(Rest, St#h1_parser{buffer = Rest}, 0);
        _ ->
            dispatch_first_line(St)
    end.

dispatch_first_line(#h1_parser{type = request} = St) ->
    parse_request_line(St);
dispatch_first_line(#h1_parser{type = response} = St) ->
    parse_response_line(St);
dispatch_first_line(#h1_parser{type = auto} = St) ->
    case parse_request_line(St) of
        {request, _M, _U, _V, _P} = R -> R;
        {error, _} -> parse_response_line(St)
    end.

match_eol(<<$\n, _/binary>>, N) -> N;
match_eol(<<_, Rest/binary>>, N) -> match_eol(Rest, N + 1);
match_eol(<<>>, _) -> nomatch.

%% --- request line -----------------------------------------------------------

parse_request_line(#h1_parser{buffer = B} = St) ->
    parse_method(B, St, <<>>).

parse_method(<<>>, _St, _Acc) -> {error, bad_request};
parse_method(<<$\r, _/binary>>, _St, _Acc) -> {error, bad_request};
parse_method(<<$\s, Rest/binary>>, St, Acc) when byte_size(Acc) > 0 ->
    parse_uri(Rest, St, Acc);
parse_method(<<C, Rest/binary>>, St, Acc) when C > 32, C < 127, C =/= $: ->
    Acc2 = <<Acc/binary, C>>,
    case byte_size(Acc2) > ?H1_MAX_METHOD_SIZE of
        true -> {error, method_too_long};
        false -> parse_method(Rest, St, Acc2)
    end;
parse_method(_, _St, _Acc) ->
    {error, invalid_method}.

parse_uri(<<$\r, _/binary>>, _St, _M) -> {error, bad_request};
parse_uri(<<"* ", Rest/binary>>, St, Method) ->
    parse_version(Rest, St, Method, <<"*">>);
parse_uri(Bin, St, Method) -> parse_uri_path(Bin, St, Method, <<>>).

parse_uri_path(<<>>, _St, _M, _Acc) -> {error, bad_request};
parse_uri_path(<<$\r, _/binary>>, _St, _M, _Acc) -> {error, bad_request};
parse_uri_path(<<$\s, Rest/binary>>, St, Method, Acc) when byte_size(Acc) > 0 ->
    parse_version(Rest, St, Method, Acc);
parse_uri_path(<<C, Rest/binary>>, St, Method, Acc) ->
    Acc2 = <<Acc/binary, C>>,
    case byte_size(Acc2) > ?H1_MAX_URI_SIZE of
        true -> {error, uri_too_long};
        false -> parse_uri_path(Rest, St, Method, Acc2)
    end.

parse_version(<<"HTTP/", Hi, ".", Lo, Rest0/binary>>, St, Method, URI)
    when Hi >= $0, Hi =< $9, Lo >= $0, Lo =< $9 ->
    Version = {Hi - $0, Lo - $0},
    case strip_crlf(Rest0) of
        {ok, Rest} ->
            NSt = St#h1_parser{type = request,
                               version = Version,
                               method = Method,
                               state = on_header,
                               buffer = Rest,
                               partial_headers = []},
            {request, Method, URI, Version, NSt};
        error ->
            {error, bad_request}
    end;
parse_version(_, _, _, _) ->
    {error, bad_request}.

strip_crlf(<<"\r\n", Rest/binary>>) -> {ok, Rest};
strip_crlf(<<"\n", Rest/binary>>)   -> {ok, Rest};
strip_crlf(_)                       -> error.

%% --- response line ----------------------------------------------------------

parse_response_line(#h1_parser{buffer = B} = St) ->
    parse_response_line_sep([<<"\r\n">>, <<"\n">>], B, St).

parse_response_line_sep([], _B, _St) ->
    {error, bad_request};
parse_response_line_sep([Sep | Rest], B, St) ->
    case binary:split(B, Sep) of
        [Line, Tail] ->
            parse_response_version(Line, St#h1_parser{buffer = Tail});
        [B] ->
            parse_response_line_sep(Rest, B, St)
    end.

parse_response_version(<<"HTTP/", Hi, ".", Lo, $\s, Rest/binary>>, St)
    when Hi >= $0, Hi =< $9, Lo >= $0, Lo =< $9 ->
    parse_status_code(Rest, St, {Hi - $0, Lo - $0}, <<>>);
parse_response_version(_, _) ->
    {error, bad_request}.

parse_status_code(<<>>, St, Version, Acc) ->
    parse_reason_phrase(<<>>, St, Version, Acc);
parse_status_code(<<$\s, Rest/binary>>, St, Version, Acc) ->
    parse_reason_phrase(Rest, St, Version, Acc);
parse_status_code(<<$\r, _/binary>>, _St, _V, _A) ->
    {error, bad_request};
parse_status_code(<<C, Rest/binary>>, St, Version, Acc) ->
    parse_status_code(Rest, St, Version, <<Acc/binary, C>>).

parse_reason_phrase(Reason, St, Version, CodeBin) ->
    case to_int(CodeBin) of
        {ok, Status} when Status >= 100, Status =< 599 ->
            NSt = St#h1_parser{type = response,
                               version = Version,
                               state = on_header,
                               partial_headers = []},
            {response, Version, Status, Reason, NSt};
        _ ->
            {error, bad_request}
    end.

%% ----------------------------------------------------------------------------
%% Headers
%% ----------------------------------------------------------------------------

parse_header_step(#h1_parser{header_count = N, max_headers = Max})
    when N >= Max ->
    {error, too_many_headers};
parse_header_step(#h1_parser{} = St) ->
    parse_header_sep([<<"\r\n">>, <<"\n">>], St).

parse_header_sep([], St) ->
    {more, St};
parse_header_sep([Sep | Rest], #h1_parser{buffer = B} = St) ->
    case binary:split(B, Sep) of
        [_, _] -> parse_header_line(Sep, St);
        [B]    -> parse_header_sep(Rest, St)
    end.

parse_header_line(Sep, #h1_parser{buffer = B} = St) ->
    case binary:split(B, Sep) of
        [<<>>, Rest] ->
            %% End of headers — enforce RFC 9112 §6.1 (CL + TE).
            case finalize_headers(St#h1_parser{buffer = Rest,
                                               state = on_body}) of
                {ok, St1} -> {headers_complete, St1};
                {error, _} = E -> E
            end;
        [Line, <<$\s, Tail/binary>>] ->
            %% Obsolete line folding; join and retry.
            parse_header_line(Sep, St#h1_parser{
                buffer = iolist_to_binary([Line, $\s, Tail])});
        [Line, <<$\t, Tail/binary>>] ->
            parse_header_line(Sep, St#h1_parser{
                buffer = iolist_to_binary([Line, $\s, Tail])});
        [Line, Rest] ->
            case split_header(Line) of
                {ok, Key, Value} ->
                    ValidName = valid_header_name(Key),
                    case {ValidName, byte_size(Key), byte_size(Value)} of
                        {true, KN, _} when KN > (St#h1_parser.max_header_name_size) ->
                            {error, header_name_too_long};
                        {true, _, VN} when VN > (St#h1_parser.max_header_value_size) ->
                            {error, header_value_too_long};
                        {true, _, _} ->
                            St1 = absorb_header(Key, Value,
                                                St#h1_parser{buffer = Rest,
                                                             header_count =
                                                                 St#h1_parser.header_count + 1}),
                            {header, {Key, Value}, St1};
                        {false, _, _} ->
                            {error, invalid_header_name}
                    end;
                {error, R} ->
                    {error, R}
            end;
        [B] ->
            {more, St}
    end.

split_header(Line) ->
    case binary:split(Line, <<":">>) of
        [_] -> {error, invalid_header_name};
        [Key, Value] ->
            case valid_header_name(Key) of
                true -> {ok, Key, trim(Value)};
                false -> {error, invalid_header_name}
            end
    end.

valid_header_name(<<>>) -> false;
valid_header_name(Bin) -> valid_header_name_1(Bin).

valid_header_name_1(<<>>) -> true;
valid_header_name_1(<<C, Rest/binary>>)
    when C > 32, C =/= 127, C =/= $:, C =/= $(, C =/= $), C =/= $,, C =/= $/,
         C =/= $;, C =/= $<, C =/= $=, C =/= $>, C =/= $?, C =/= $@,
         C =/= $[, C =/= $\\, C =/= $], C =/= ${, C =/= $}, C =/= $" ->
    valid_header_name_1(Rest);
valid_header_name_1(_) ->
    false.

%% Capture fast-path headers into the parser record (lowercased).
absorb_header(Key, Value, St) ->
    St1 = St#h1_parser{partial_headers = [{Key, Value} | St#h1_parser.partial_headers]},
    update_fast_path(Key, Value, St1).

%% Byte-size dispatch avoids to_lower/1 on every header (hackney trick).
update_fast_path(Key, Value, St) ->
    case byte_size(Key) of
        14 -> maybe_set_clen(Key, Value, St);
        17 -> maybe_set_te(Key, Value, St);
        10 -> maybe_set_connection(Key, Value, St);
        12 -> maybe_set_ctype(Key, Value, St);
        8  -> maybe_set_location(Key, Value, St);
        16 -> maybe_set_ce(Key, Value, St);
        7  -> maybe_set_upgrade(Key, Value, St);
        6  -> maybe_set_expect(Key, Value, St);
        _  -> St
    end.

maybe_set_clen(K, V, St) ->
    case to_lower(K) of
        <<"content-length">> ->
            case to_int(V) of
                {ok, N} when N >= 0 -> St#h1_parser{clen = N};
                _ -> St#h1_parser{clen = bad_int}
            end;
        _ -> St
    end.

maybe_set_te(K, V, St) ->
    case to_lower(K) of
        <<"transfer-encoding">> -> St#h1_parser{te = to_lower(V)};
        _ -> St
    end.

maybe_set_connection(K, V, St) ->
    case to_lower(K) of
        <<"connection">> -> St#h1_parser{connection = to_lower(V)};
        _ -> St
    end.

maybe_set_ctype(K, V, St) ->
    case to_lower(K) of
        <<"content-type">> -> St#h1_parser{ctype = to_lower(V)};
        _ -> St
    end.

maybe_set_location(K, V, St) ->
    case to_lower(K) of
        <<"location">> -> St#h1_parser{location = V};
        _ -> St
    end.

maybe_set_ce(K, V, St) ->
    case to_lower(K) of
        <<"content-encoding">> -> St#h1_parser{content_encoding = to_lower(V)};
        _ -> St
    end.

maybe_set_upgrade(K, V, St) ->
    case to_lower(K) of
        <<"upgrade">> -> St#h1_parser{upgrade = to_lower(V)};
        _ -> St
    end.

maybe_set_expect(K, V, St) ->
    case to_lower(K) of
        <<"expect">> -> St#h1_parser{expect = to_lower(V)};
        _ -> St
    end.

%% RFC 9112 §6.1: Content-Length + Transfer-Encoding on the same message
%% must be rejected. Prevents request smuggling.
finalize_headers(#h1_parser{te = TE, clen = CL} = St)
    when TE =/= undefined, CL =/= undefined, CL =/= bad_int ->
    case has_chunked(TE) of
        true -> {error, conflicting_framing};
        false -> {ok, St}
    end;
finalize_headers(#h1_parser{clen = bad_int}) ->
    {error, bad_request};
finalize_headers(St) ->
    {ok, St}.

has_chunked(TE) ->
    %% Transfer-Encoding may be a list: "gzip, chunked".
    lists:any(fun(X) -> trim(X) =:= <<"chunked">> end,
              binary:split(TE, <<",">>, [global])).

%% ----------------------------------------------------------------------------
%% Body
%% ----------------------------------------------------------------------------

parse_body(#h1_parser{method = <<"HEAD">>, buffer = B}) ->
    %% No body on HEAD response.
    {done, B};
parse_body(#h1_parser{body_state = waiting, te = TE} = St) ->
    case has_chunked_safe(TE) of
        true ->
            parse_body(St#h1_parser{body_state =
                {stream, fun te_chunked/2, waiting_size, fun ce_identity/1}});
        false ->
            case St#h1_parser.clen of
                undefined ->
                    {done, St#h1_parser.buffer};
                0 ->
                    {done, St#h1_parser.buffer};
                bad_int ->
                    {error, bad_request};
                N when is_integer(N), N > 0 ->
                    parse_body(St#h1_parser{body_state =
                        {stream, fun te_identity/2, {0, N}, fun ce_identity/1}})
            end
    end;
parse_body(#h1_parser{body_state = done, buffer = B}) ->
    {done, B};
parse_body(#h1_parser{buffer = B, body_state = {stream, _, _, _}} = St)
    when byte_size(B) > 0 ->
    transfer_decode(B, St#h1_parser{buffer = <<>>});
parse_body(#h1_parser{} = St) ->
    {more, St, <<>>}.

has_chunked_safe(undefined) -> false;
has_chunked_safe(TE) -> has_chunked(TE).

transfer_decode(Data, #h1_parser{
    body_state = {stream, TD, TS, CD}, buffer = Buf} = St) ->
    case TD(Data, TS) of
        {ok, Data2, TS2} ->
            content_decode(CD, Data2,
                St#h1_parser{body_state = {stream, TD, TS2, CD}});
        {ok, Data2, Rest, TS2} ->
            content_decode(CD, Data2,
                St#h1_parser{buffer = Rest,
                             body_state = {stream, TD, TS2, CD}});
        {chunk_ok, Chunk, Rest} ->
            {ok, Chunk, St#h1_parser{buffer = Rest}};
        {chunk_done, Rest} ->
            parse_trailer_step(St#h1_parser{buffer = Rest,
                                            state = on_trailers,
                                            body_state = done,
                                            header_count = 0});
        more ->
            {more, St#h1_parser{buffer = Data}, Buf};
        {more, TS2} ->
            {more, St#h1_parser{buffer = Data,
                                body_state = {stream, TD, TS2, CD}}, Buf};
        {done, Rest} ->
            {done, Rest};
        {done, Data2, Rest} ->
            content_decode(CD, Data2,
                St#h1_parser{buffer = Rest, body_state = done});
        {done, Data2, _Total, Rest} ->
            content_decode(CD, Data2,
                St#h1_parser{buffer = Rest, body_state = done});
        done ->
            {done, <<>>};
        {error, R} ->
            {error, R}
    end.

content_decode(CD, Data, St) ->
    case CD(Data) of
        {ok, Data2} -> {ok, Data2, St};
        {error, R} -> {error, R}
    end.

ce_identity(Data) -> {ok, Data}.

%% --- identity body decoder --------------------------------------------------

te_identity(Data, {Streamed, Total})
    when (Streamed + byte_size(Data)) < Total ->
    {ok, Data, {Streamed + byte_size(Data), Total}};
te_identity(Data, {Streamed, Total}) ->
    Size = Total - Streamed,
    <<Data2:Size/binary, Rest/binary>> = Data,
    {done, Data2, Total, Rest}.

%% --- chunked body decoder ---------------------------------------------------

te_chunked(<<>>, _) -> more;
te_chunked(Data, _State) ->
    case read_size(Data) of
        {ok, 0, Rest} -> {chunk_done, Rest};
        {ok, Size, Rest} ->
            case read_chunk(Rest, Size) of
                {ok, Chunk, Rest2} -> {chunk_ok, Chunk, Rest2};
                eof -> more
            end;
        eof -> more;
        {error, R} -> {error, R}
    end.

read_size(Data) -> read_size(Data, 0, 0).

read_size(<<>>, _, _) -> eof;
read_size(<<"\r\n", Rest/binary>>, Size, Len) when Len > 0 ->
    {ok, Size, Rest};
read_size(<<"\n", Rest/binary>>, Size, Len) when Len > 0 ->
    {ok, Size, Rest};
read_size(<<"\r\n", _/binary>>, _, 0) -> eof;
read_size(<<"\n", _/binary>>, _, 0) -> eof;
read_size(<<$;, Rest/binary>>, Size, Len) when Len > 0 ->
    skip_ext(Rest, Size);
read_size(<<$\s, Rest/binary>>, Size, Len) when Len > 0 ->
    skip_ext(Rest, Size);
read_size(<<C, Rest/binary>>, Size, Len) when C >= $0, C =< $9 ->
    read_size(Rest, (Size bsl 4) bor (C - $0), Len + 1);
read_size(<<C, Rest/binary>>, Size, Len) when C >= $a, C =< $f ->
    read_size(Rest, (Size bsl 4) bor (C - $a + 10), Len + 1);
read_size(<<C, Rest/binary>>, Size, Len) when C >= $A, C =< $F ->
    read_size(Rest, (Size bsl 4) bor (C - $A + 10), Len + 1);
read_size(_, _, _) ->
    {error, invalid_chunk_size}.

skip_ext(<<"\r\n", Rest/binary>>, Size) -> {ok, Size, Rest};
skip_ext(<<"\n", Rest/binary>>, Size) -> {ok, Size, Rest};
skip_ext(<<>>, _) -> eof;
skip_ext(<<_, Rest/binary>>, Size) -> skip_ext(Rest, Size).

read_chunk(Data, Size) ->
    case Data of
        <<Chunk:Size/binary, "\r\n", Rest/binary>> ->
            {ok, Chunk, Rest};
        <<Chunk:Size/binary, "\n", Rest/binary>> ->
            {ok, Chunk, Rest};
        <<_:Size/binary, Rest/binary>> when byte_size(Rest) >= 2 ->
            {error, invalid_chunk_terminator};
        _ ->
            eof
    end.

%% ----------------------------------------------------------------------------
%% Trailers (after the final 0-size chunk)
%% ----------------------------------------------------------------------------

parse_trailer_step(#h1_parser{buffer = B} = St) ->
    case match_crlf_prefix(B) of
        crlf ->
            <<_:16, Rest/binary>> = B,
            {done, Rest};
        lf ->
            <<_:8, Rest/binary>> = B,
            {done, Rest};
        more ->
            {more, St#h1_parser{state = on_trailers}, <<>>};
        no ->
            case parse_header_sep([<<"\r\n">>, <<"\n">>],
                                  St#h1_parser{state = on_trailers}) of
                {headers_complete, St1} ->
                    {done, St1#h1_parser.buffer};
                {header, {K, V}, St1} ->
                    {trailer, {K, V}, St1};
                Other ->
                    Other
            end
    end.

match_crlf_prefix(<<"\r\n", _/binary>>) -> crlf;
match_crlf_prefix(<<"\n", _/binary>>) -> lf;
match_crlf_prefix(<<"\r">>) -> more;
match_crlf_prefix(<<>>) -> more;
match_crlf_prefix(_) -> no.

%% ----------------------------------------------------------------------------
%% Junk skipping (on keep-alive, between messages)
%% ----------------------------------------------------------------------------

skip_junk(#h1_parser{buffer = B} = St) ->
    case binary:split(B, <<"\r\n">>) of
        [<<>>, Rest] ->
            {more, St#h1_parser{buffer = Rest, state = on_first_line}};
        [_Line, Rest] ->
            skip_junk(St#h1_parser{buffer = Rest});
        [B] ->
            {more, St}
    end.

%% ----------------------------------------------------------------------------
%% Stateless convenience wrappers
%% ----------------------------------------------------------------------------

-type request_result() ::
        {ok, http_method(), binary(), binary(), http_version(),
             [{binary(), binary()}], binary()}
      | {more, binary()}
      | {error, term()}.

%% @doc Parse a full request head in one call (for callers who already
%% have the complete bytes buffered). Returns path + query-string split.
-spec parse_request(binary()) -> request_result().
parse_request(Data) -> parse_request(Data, #{}).

-spec parse_request(binary(), map()) -> request_result().
parse_request(Data, Opts) ->
    P = parser([request | map_opts(Opts)]),
    consume_head(execute(P, Data), request, Data, []).

-type response_result() ::
        {ok, http_version(), status(), http_reason(),
             [{binary(), binary()}], binary()}
      | {more, binary()}
      | {error, term()}.

-spec parse_response(binary()) -> response_result().
parse_response(Data) -> parse_response(Data, #{}).

-spec parse_response(binary(), map()) -> response_result().
parse_response(Data, Opts) ->
    P = parser([response | map_opts(Opts)]),
    consume_head(execute(P, Data), response, Data, []).

map_opts(Opts) ->
    maps:fold(fun(K, V, A) -> [{K, V} | A] end, [], Opts).

consume_head({request, M, URI, V, P}, request, _Data, _Headers) ->
    collect_headers(execute(P), M, URI, V, []);
consume_head({response, V, S, R, P}, response, _Data, _Headers) ->
    collect_headers_resp(execute(P), V, S, R, []);
consume_head({more, _}, _, Data, _) ->
    {more, Data};
consume_head({error, _} = E, _, _, _) ->
    E.

collect_headers({header, KV, P}, M, U, V, Acc) ->
    collect_headers(execute(P), M, U, V, [KV | Acc]);
collect_headers({headers_complete, P}, M, U, V, Acc) ->
    {Path, Qs} = split_path(U),
    {ok, M, Path, Qs, V, lists:reverse(Acc), P#h1_parser.buffer};
collect_headers({more, P}, _, _, _, _) ->
    {more, P#h1_parser.buffer};
collect_headers({error, _} = E, _, _, _, _) ->
    E.

collect_headers_resp({header, KV, P}, V, S, R, Acc) ->
    collect_headers_resp(execute(P), V, S, R, [KV | Acc]);
collect_headers_resp({headers_complete, P}, V, S, R, Acc) ->
    {ok, V, S, R, lists:reverse(Acc), P#h1_parser.buffer};
collect_headers_resp({more, P}, _, _, _, _) ->
    {more, P#h1_parser.buffer};
collect_headers_resp({error, _} = E, _, _, _, _) ->
    E.

split_path(URI) ->
    case binary:split(URI, <<"?">>) of
        [URI]   -> {URI, <<>>};
        [P, Q]  -> {P, Q}
    end.

%% @doc Stateless chunk parser (livery style) — useful when caller drives
%% the body loop directly.
parse_chunk(Data) -> parse_chunk(Data, ?H1_MAX_CHUNK_SIZE).
parse_chunk(Data, MaxSize) ->
    case read_size(Data) of
        {ok, 0, Rest} -> {done, Rest};
        {ok, Size, _Rest} when Size > MaxSize -> {error, chunk_too_large};
        {ok, Size, Rest} ->
            case read_chunk(Rest, Size) of
                {ok, Chunk, Rest2} -> {ok, Chunk, Rest2};
                eof -> {more, Data};
                {error, R} -> {error, R}
            end;
        eof -> {more, Data};
        {error, R} -> {error, R}
    end.

parse_trailers(Data) ->
    parse_trailers_loop(Data, []).

parse_trailers_loop(<<"\r\n", Rest/binary>>, Acc) ->
    {ok, lists:reverse(Acc), Rest};
parse_trailers_loop(<<"\n", Rest/binary>>, Acc) ->
    {ok, lists:reverse(Acc), Rest};
parse_trailers_loop(<<>>, _Acc) ->
    {more, <<>>};
parse_trailers_loop(Data, Acc) ->
    case binary:split(Data, [<<"\r\n">>, <<"\n">>]) of
        [Data] -> {more, Data};
        [Line, Rest] ->
            case split_header(Line) of
                {ok, K, V} -> parse_trailers_loop(Rest, [{K, V} | Acc]);
                {error, R} -> {error, R}
            end
    end.

%% ----------------------------------------------------------------------------
%% Binary/string helpers (inlined to avoid hackney_bstr dependency)
%% ----------------------------------------------------------------------------

-spec to_lower(binary()) -> binary().
to_lower(Bin) when is_binary(Bin) ->
    << <<(to_lower_char(C))>> || <<C>> <= Bin >>.

to_lower_char(C) when C >= $A, C =< $Z -> C + 32;
to_lower_char(C) -> C.

-spec trim(binary()) -> binary().
trim(Bin) ->
    trim_trailing(trim_leading(Bin)).

trim_leading(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t ->
    trim_leading(Rest);
trim_leading(B) -> B.

trim_trailing(<<>>) -> <<>>;
trim_trailing(B) ->
    Sz = byte_size(B) - 1,
    case binary:at(B, Sz) of
        C when C =:= $\s; C =:= $\t ->
            trim_trailing(binary:part(B, 0, Sz));
        _ ->
            B
    end.

-spec to_int(binary()) -> {ok, non_neg_integer()} | false.
to_int(Bin) ->
    try
        {ok, binary_to_integer(Bin)}
    catch
        _:_ -> false
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

to_lower_test_() ->
    [?_assertEqual(<<"hello world">>, to_lower(<<"Hello World">>)),
     ?_assertEqual(<<"">>, to_lower(<<"">>)),
     ?_assertEqual(<<"a1b2c3">>, to_lower(<<"A1B2C3">>))].

trim_test_() ->
    [?_assertEqual(<<"abc">>, trim(<<" \tabc \t">>)),
     ?_assertEqual(<<"">>, trim(<<"">>)),
     ?_assertEqual(<<"a b">>, trim(<<" a b ">>))].

to_int_test_() ->
    [?_assertEqual({ok, 42}, to_int(<<"42">>)),
     ?_assertEqual(false,    to_int(<<"xx">>)),
     ?_assertEqual(false,    to_int(<<"">>))].

-endif.
