%%% @doc PropEr properties for the H1 parser + encoder.
%%%
%%% The central property: for every well-formed request/response/chunk
%%% we can build via h1_message, the parser returns the same bytes we
%%% put in. Exercised via random generators to catch edge cases the
%%% hand-written suites miss.
-module(h1_prop_tests).

-ifdef(PROPER).

-include_lib("proper/include/proper.hrl").
-include("h1.hrl").

%% ---- generators ------------------------------------------------------------

token_char() ->
    oneof([integer($a, $z), integer($A, $Z), integer($0, $9),
           $-, $_, $.]).

token() ->
    ?LET(Cs, non_empty(list(token_char())), list_to_binary(Cs)).

method() ->
    oneof([<<"GET">>, <<"POST">>, <<"PUT">>, <<"DELETE">>,
           <<"HEAD">>, <<"OPTIONS">>, <<"PATCH">>]).

path() ->
    ?LET(Cs, non_empty(list(oneof([integer($a, $z), integer($0, $9), $/, $-, $_]))),
         iolist_to_binary([$/, Cs])).

header_value_char() ->
    oneof([integer($a, $z), integer($A, $Z), integer($0, $9),
           $\s, $-, $_, $., $,, $:, $/]).

header_value() ->
    ?LET(Cs, list(header_value_char()),
         h1_parse_erl:trim(list_to_binary(Cs))).

header_name() -> token().

header() -> {header_name(), header_value()}.

headers() -> list(header()).

body() -> binary().

%% ---- properties ------------------------------------------------------------

prop_request_roundtrip() ->
    ?FORALL({Method, Path, Headers, Body},
            {method(), path(), headers(), body()},
        begin
            %% Drop empty-value headers (trim returned <<>> which would
            %% produce "Name: \r\n" — valid but awkward for test).
            Hs = [{N, V} || {N, V} <- Headers, V =/= <<>>],
            Bin = iolist_to_binary(
                    h1_message:encode_request(Method, Path, Hs, Body)),
            case h1_parse:parse_request(Bin) of
                {ok, M2, P2, _Qs, {1, 1}, _Parsed, Rest} ->
                    M2 =:= Method
                        andalso P2 =:= Path
                        andalso Rest =:= Body;
                _ -> false
            end
        end).

prop_response_roundtrip() ->
    ?FORALL({Status, Headers, Body},
            {integer(200, 599), headers(), body()},
        begin
            Hs = [{N, V} || {N, V} <- Headers, V =/= <<>>],
            Bin = iolist_to_binary(h1_message:encode_response(Status, Hs, Body)),
            case h1_parse:parse_response(Bin) of
                {ok, {1, 1}, S2, _Reason, _Parsed, Rest} ->
                    S2 =:= Status andalso Rest =:= Body;
                _ -> false
            end
        end).

prop_chunked_roundtrip() ->
    ?FORALL(Chunks, non_empty(list(non_empty(binary()))),
        begin
            Bin = iolist_to_binary(
                [[h1_message:encode_chunk(C) || C <- Chunks],
                 h1_message:encode_last_chunk()]),
            case collect_chunks(Bin, []) of
                {ok, Collected} -> iolist_to_binary(Collected) =:= iolist_to_binary(Chunks);
                _ -> false
            end
        end).

prop_capsule_roundtrip() ->
    ?FORALL({Type, Payload}, {integer(0, 16#3FFFFFFF), binary()},
        begin
            Enc = h1_capsule:encode(Type, Payload),
            case h1_capsule:decode(Enc) of
                {ok, {DecType, Payload}, <<>>} ->
                    normalise_type(DecType) =:= Type;
                _ -> false
            end
        end).

normalise_type(datagram) -> 0;
normalise_type(N) -> N.

collect_chunks(Data, Acc) ->
    case h1_parse_erl:parse_chunk(Data) of
        {ok, C, Rest} -> collect_chunks(Rest, [C | Acc]);
        {done, _} -> {ok, lists:reverse(Acc)};
        {more, _} -> {more, Acc};
        {error, R} -> {error, R}
    end.

-endif.
