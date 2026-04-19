%% @doc HTTP/1.1 message encoder.
%%
%% Builds iolists suitable for direct use with gen_tcp:send / ssl:send.
%% Covers: request line, status line, header block, chunked body frames,
%% trailer block. Also helpers for Content-Length / Transfer-Encoding
%% auto-selection.
%%
%% Based on livery_resp.erl (enki-multimedia) with additions for
%% client-side request building.
-module(h1_message).

-export([
    %% Request side
    request_line/3, request_line/4,
    %% Response side
    status_line/2, status_line/3,
    status_text/1,
    %% Shared
    headers/1,
    encode/3, encode/4,
    encode_response/3, encode_response/4,
    encode_request/3, encode_request/4,
    %% Chunked streaming
    encode_chunk/1,
    encode_last_chunk/0, encode_last_chunk/1,
    %% Framing helpers
    choose_framing/2,
    is_valid_header_name/1,
    is_valid_header_value/1,
    is_valid_token/1,
    is_valid_request_target/1,
    is_valid_reason_phrase/1
]).

-include("h1.hrl").

-type version() :: {non_neg_integer(), non_neg_integer()}.
-type headers() :: [{binary(), iodata()}].

-export_type([version/0, headers/0]).

%% ----------------------------------------------------------------------------
%% Request line
%% ----------------------------------------------------------------------------

-spec request_line(binary(), binary(), version()) -> iodata().
request_line(Method, Path, Version) ->
    request_line(Method, Path, <<>>, Version).

-spec request_line(binary(), binary(), binary(), version()) -> iodata().
request_line(Method, Path, Qs, Version) ->
    ok = check_token(Method, invalid_method),
    ok = check_request_target(Path, invalid_path),
    ok = check_request_target(Qs, invalid_query),
    case Qs of
        <<>> -> [Method, $\s, Path, $\s, version_bin(Version), "\r\n"];
        _    -> [Method, $\s, Path, $?, Qs, $\s, version_bin(Version), "\r\n"]
    end.

check_token(Bin, Tag) ->
    case is_valid_token(Bin) of
        true  -> ok;
        false -> error({Tag, Bin})
    end.

check_request_target(Bin, Tag) ->
    case is_valid_request_target(Bin) of
        true  -> ok;
        false -> error({Tag, Bin})
    end.

check_reason(Bin) ->
    case is_valid_reason_phrase(Bin) of
        true  -> ok;
        false -> error({invalid_reason_phrase, Bin})
    end.

%% ----------------------------------------------------------------------------
%% Status line
%% ----------------------------------------------------------------------------

-spec status_line(non_neg_integer(), version()) -> iodata().
status_line(Status, Version) ->
    status_line(Status, status_text(Status), Version).

-spec status_line(non_neg_integer(), binary(), version()) -> iodata().
status_line(Status, Reason, Version) ->
    ok = check_reason(Reason),
    [version_bin(Version), $\s, integer_to_binary(Status), $\s, Reason, "\r\n"].

version_bin({1, 0}) -> <<"HTTP/1.0">>;
version_bin({1, 1}) -> <<"HTTP/1.1">>;
version_bin({Maj, Min}) ->
    [<<"HTTP/">>, integer_to_binary(Maj), $., integer_to_binary(Min)].

%% ----------------------------------------------------------------------------
%% Headers
%% ----------------------------------------------------------------------------

-spec headers(headers()) -> iodata().
headers(Headers) ->
    [encode_header_kv(N, V) || {N, V} <- Headers].

encode_header_kv(Name, Value) ->
    case {is_valid_header_name(Name), is_valid_header_value(Value)} of
        {true, true}  -> [Name, <<": ">>, Value, <<"\r\n">>];
        {false, _}    -> error({invalid_header_name, Name});
        {_, false}    -> error({invalid_header_value, Name})
    end.

%% Reject CR/LF in header values (header injection guard).
-spec is_valid_header_value(iodata()) -> boolean().
is_valid_header_value(Bin) when is_binary(Bin) ->
    binary:match(Bin, [<<"\r">>, <<"\n">>]) =:= nomatch;
is_valid_header_value(Value) ->
    is_valid_header_value(iolist_to_binary(Value)).

%% RFC 9110 §5.1: field-name = token = 1*tchar. We reject any byte that
%% isn't a printable ASCII tchar — this catches CR/LF injection but also
%% space, colon, DEL, and control bytes.
-spec is_valid_header_name(iodata()) -> boolean().
is_valid_header_name(<<>>) -> false;
is_valid_header_name(Bin) when is_binary(Bin) -> is_tchar_binary(Bin);
is_valid_header_name(Name) -> is_valid_header_name(iolist_to_binary(Name)).

-spec is_valid_token(iodata()) -> boolean().
is_valid_token(<<>>) -> false;
is_valid_token(Bin) when is_binary(Bin) -> is_tchar_binary(Bin);
is_valid_token(Tok) -> is_valid_token(iolist_to_binary(Tok)).

is_tchar_binary(<<>>) -> true;
is_tchar_binary(<<C, Rest/binary>>) ->
    case is_tchar(C) of
        true  -> is_tchar_binary(Rest);
        false -> false
    end.

%% RFC 9110 token character set.
is_tchar(C) when C >= $0, C =< $9 -> true;
is_tchar(C) when C >= $a, C =< $z -> true;
is_tchar(C) when C >= $A, C =< $Z -> true;
is_tchar($!) -> true; is_tchar($#) -> true; is_tchar($$) -> true;
is_tchar($%) -> true; is_tchar($&) -> true; is_tchar($') -> true;
is_tchar($*) -> true; is_tchar($+) -> true; is_tchar($-) -> true;
is_tchar($.) -> true; is_tchar($^) -> true; is_tchar($_) -> true;
is_tchar($`) -> true; is_tchar($|) -> true; is_tchar($~) -> true;
is_tchar(_)  -> false.

%% RFC 9112 §3.2 request-target — no CR/LF/SP in the serialized form.
-spec is_valid_request_target(iodata()) -> boolean().
is_valid_request_target(<<>>) -> true;
is_valid_request_target(Bin) when is_binary(Bin) -> is_visible_ascii(Bin);
is_valid_request_target(X) -> is_valid_request_target(iolist_to_binary(X)).

is_visible_ascii(<<>>) -> true;
is_visible_ascii(<<C, R/binary>>) when C > 32, C =/= 127 -> is_visible_ascii(R);
is_visible_ascii(_) -> false.

%% RFC 9110 §4.1 reason-phrase = *( HTAB / SP / VCHAR / obs-text )
-spec is_valid_reason_phrase(iodata()) -> boolean().
is_valid_reason_phrase(<<>>) -> true;
is_valid_reason_phrase(Bin) when is_binary(Bin) -> is_reason_binary(Bin);
is_valid_reason_phrase(X) -> is_valid_reason_phrase(iolist_to_binary(X)).

is_reason_binary(<<>>) -> true;
is_reason_binary(<<$\t, R/binary>>) -> is_reason_binary(R);
is_reason_binary(<<C, R/binary>>) when C >= 32, C =/= 127 -> is_reason_binary(R);
is_reason_binary(_) -> false.

%% ----------------------------------------------------------------------------
%% High-level encoders
%% ----------------------------------------------------------------------------

%% @doc Build a full response: status line + headers + body. Auto-adds
%% Content-Length when the body is fully known.
-spec encode_response(non_neg_integer(), headers(), iodata()) -> iodata().
encode_response(Status, Headers, Body) ->
    encode_response(Status, Headers, Body, ?HTTP_1_1).

-spec encode_response(non_neg_integer(), headers(), iodata(), version()) -> iodata().
encode_response(Status, Headers, Body, Version) ->
    encode(status_line(Status, Version), Headers, Body).

%% @doc Build a full request: request line + headers + body.
-spec encode_request(binary(), binary(), headers()) -> iodata().
encode_request(Method, Path, Headers) ->
    encode_request(Method, Path, Headers, <<>>).

-spec encode_request(binary(), binary(), headers(), iodata()) -> iodata().
encode_request(Method, Path, Headers, Body) ->
    encode(request_line(Method, Path, ?HTTP_1_1), Headers, Body).

%% @doc Assemble a message from a head line, headers and body. Adds
%% Content-Length when missing and body is not chunked.
-spec encode(iodata(), headers(), iodata()) -> iodata().
encode(Head, Headers, Body) ->
    encode(Head, Headers, Body, #{}).

-spec encode(iodata(), headers(), iodata(), map()) -> iodata().
encode(Head, Headers, Body, _Opts) ->
    BodyBin = iolist_to_binary(Body),
    Headers1 = ensure_content_length(Headers, BodyBin),
    [Head, headers(Headers1), <<"\r\n">>, BodyBin].

%% ----------------------------------------------------------------------------
%% Chunked streaming
%% ----------------------------------------------------------------------------

-spec encode_chunk(iodata()) -> iodata().
encode_chunk(<<>>) ->
    %% A zero-size chunk would be interpreted as "last-chunk"; callers
    %% must use encode_last_chunk/0,1 explicitly.
    <<>>;
encode_chunk(Data) ->
    Bin = iolist_to_binary(Data),
    case byte_size(Bin) of
        0 -> <<>>;
        Size ->
            SizeHex = integer_to_binary(Size, 16),
            [SizeHex, <<"\r\n">>, Bin, <<"\r\n">>]
    end.

-spec encode_last_chunk() -> binary().
encode_last_chunk() ->
    <<"0\r\n\r\n">>.

-spec encode_last_chunk(headers()) -> iodata().
encode_last_chunk([]) -> encode_last_chunk();
encode_last_chunk(Trailers) ->
    [<<"0\r\n">>, headers(Trailers), <<"\r\n">>].

%% ----------------------------------------------------------------------------
%% Framing selection
%% ----------------------------------------------------------------------------

%% @doc Decide how to frame an outgoing message body.
%%
%% Returns `{content_length, N, Headers}' when Content-Length will be used
%% (body is a fully-known binary/iodata), `{chunked, Headers}' when caller
%% opted into streaming, or `{no_body, Headers}' for bodyless messages.
-spec choose_framing(iodata() | chunked | no_body, headers()) ->
    {content_length, non_neg_integer(), headers()}
  | {chunked, headers()}
  | {no_body, headers()}.
choose_framing(no_body, Headers) ->
    {no_body, drop_header(<<"content-length">>, drop_header(<<"transfer-encoding">>, Headers))};
choose_framing(chunked, Headers) ->
    H1 = drop_header(<<"content-length">>, Headers),
    H2 = case has_header(<<"transfer-encoding">>, H1) of
             true -> H1;
             false -> H1 ++ [{<<"transfer-encoding">>, <<"chunked">>}]
         end,
    {chunked, H2};
choose_framing(Body, Headers) ->
    Bin = iolist_to_binary(Body),
    Size = byte_size(Bin),
    H1 = drop_header(<<"transfer-encoding">>, Headers),
    H2 = case has_header(<<"content-length">>, H1) of
             true -> H1;
             false -> H1 ++ [{<<"content-length">>, integer_to_binary(Size)}]
         end,
    {content_length, Size, H2}.

ensure_content_length(Headers, Body) ->
    case has_header(<<"content-length">>, Headers)
      orelse has_header(<<"transfer-encoding">>, Headers) of
        true -> Headers;
        false -> Headers ++ [{<<"content-length">>, integer_to_binary(byte_size(Body))}]
    end.

has_header(Needle, Headers) ->
    Lower = Needle,
    lists:any(fun({N, _}) -> h1_parse_erl:to_lower(N) =:= Lower end, Headers).

drop_header(Needle, Headers) ->
    Lower = Needle,
    [{N, V} || {N, V} <- Headers, h1_parse_erl:to_lower(N) =/= Lower].

%% ----------------------------------------------------------------------------
%% Status text table (RFC 9110 §15 + common extensions)
%% ----------------------------------------------------------------------------

-spec status_text(non_neg_integer()) -> binary().
status_text(100) -> <<"Continue">>;
status_text(101) -> <<"Switching Protocols">>;
status_text(102) -> <<"Processing">>;
status_text(103) -> <<"Early Hints">>;
status_text(200) -> <<"OK">>;
status_text(201) -> <<"Created">>;
status_text(202) -> <<"Accepted">>;
status_text(203) -> <<"Non-Authoritative Information">>;
status_text(204) -> <<"No Content">>;
status_text(205) -> <<"Reset Content">>;
status_text(206) -> <<"Partial Content">>;
status_text(207) -> <<"Multi-Status">>;
status_text(208) -> <<"Already Reported">>;
status_text(226) -> <<"IM Used">>;
status_text(300) -> <<"Multiple Choices">>;
status_text(301) -> <<"Moved Permanently">>;
status_text(302) -> <<"Found">>;
status_text(303) -> <<"See Other">>;
status_text(304) -> <<"Not Modified">>;
status_text(307) -> <<"Temporary Redirect">>;
status_text(308) -> <<"Permanent Redirect">>;
status_text(400) -> <<"Bad Request">>;
status_text(401) -> <<"Unauthorized">>;
status_text(402) -> <<"Payment Required">>;
status_text(403) -> <<"Forbidden">>;
status_text(404) -> <<"Not Found">>;
status_text(405) -> <<"Method Not Allowed">>;
status_text(406) -> <<"Not Acceptable">>;
status_text(407) -> <<"Proxy Authentication Required">>;
status_text(408) -> <<"Request Timeout">>;
status_text(409) -> <<"Conflict">>;
status_text(410) -> <<"Gone">>;
status_text(411) -> <<"Length Required">>;
status_text(412) -> <<"Precondition Failed">>;
status_text(413) -> <<"Content Too Large">>;
status_text(414) -> <<"URI Too Long">>;
status_text(415) -> <<"Unsupported Media Type">>;
status_text(416) -> <<"Range Not Satisfiable">>;
status_text(417) -> <<"Expectation Failed">>;
status_text(418) -> <<"I'm a teapot">>;
status_text(421) -> <<"Misdirected Request">>;
status_text(422) -> <<"Unprocessable Content">>;
status_text(425) -> <<"Too Early">>;
status_text(426) -> <<"Upgrade Required">>;
status_text(428) -> <<"Precondition Required">>;
status_text(429) -> <<"Too Many Requests">>;
status_text(431) -> <<"Request Header Fields Too Large">>;
status_text(451) -> <<"Unavailable For Legal Reasons">>;
status_text(500) -> <<"Internal Server Error">>;
status_text(501) -> <<"Not Implemented">>;
status_text(502) -> <<"Bad Gateway">>;
status_text(503) -> <<"Service Unavailable">>;
status_text(504) -> <<"Gateway Timeout">>;
status_text(505) -> <<"HTTP Version Not Supported">>;
status_text(506) -> <<"Variant Also Negotiates">>;
status_text(507) -> <<"Insufficient Storage">>;
status_text(508) -> <<"Loop Detected">>;
status_text(510) -> <<"Not Extended">>;
status_text(511) -> <<"Network Authentication Required">>;
status_text(_) -> <<"Unknown">>.
