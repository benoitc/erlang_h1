%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
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

%% ---- bodyless response framing (RFC 9112 §6) --------------------------------
%%
%% Drives a real server over loopback. Each case is one request answered
%% through one send path, followed by `GET /next' on the same socket. The
%% raw bytes must frame the first response per RFC 9112 §6: a response to
%% HEAD and any 1xx, 204 or 304 has no Transfer-Encoding and nothing after
%% its header block (no Content-Length either on 1xx and 204); any other
%% response carries exactly the body that was sent. The next response must
%% start right after. Run from h1_bodyless_SUITE:framing_property/1.

-define(BODYLESS_REG, h1_prop_bodyless).

prop_bodyless_framing() ->
    ?SETUP(fun bodyless_setup/0,
        ?FORALL(Case, bodyless_case(),
            begin
                Port = persistent_term:get(?BODYLESS_REG),
                bodyless_check(Case, bodyless_exchange(Port, Case))
            end)).

bodyless_setup() ->
    Handler = fun(Conn, Id, _Method, Path, _Hs) ->
                  bodyless_handle(Conn, Id, Path)
              end,
    {ok, Ref} = h1:start_server(0, #{transport => tcp, handler => Handler,
                                    acceptors => 2}),
    persistent_term:put(?BODYLESS_REG, h1:server_port(Ref)),
    fun() ->
        persistent_term:erase(?BODYLESS_REG),
        h1:stop_server(Ref)
    end.

bodyless_case() ->
    ?LET({Method, Status, Path, Chunks},
         {oneof([<<"GET">>, <<"HEAD">>, <<"POST">>]),
          oneof([100, 102, 103, 200, 204, 205, 304, 404, 500]),
          oneof([respond, stream, stream_trailers]),
          list(binary())},
         ?LET(Framing, bodyless_framing(Path),
              {Method, Status, Path, Chunks, Framing})).

%% Trailers need chunked framing on a response that has a body.
bodyless_framing(stream_trailers) -> oneof([none, te]);
bodyless_framing(_) -> oneof([none, cl, te]).

bodyless_handle(Conn, Id, <<"/next">>) ->
    h1:respond(Conn, Id, 200, [], <<"ok">>);
bodyless_handle(Conn, Id, <<"/case/", Enc/binary>>) ->
    {From, {_Method, Status, Path, Chunks, Framing}} =
        binary_to_term(base64:decode(Enc, #{mode => urlsafe, padding => false})),
    Hs = case Framing of
        none -> [];
        cl -> [{<<"content-length">>,
                integer_to_binary(iolist_size(Chunks))}];
        te -> [{<<"transfer-encoding">>, <<"chunked">>}]
    end,
    Results = bodyless_send(Conn, Id, Status, Hs, Path, Chunks),
    %% A 1xx is interim: the final response follows on the same stream.
    Final = case Status < 200 of
        true -> [h1:respond(Conn, Id, 200, [], <<"f">>)];
        false -> []
    end,
    From ! {bodyless_sent, Results ++ Final},
    ok.

bodyless_send(Conn, Id, Status, Hs, respond, Chunks) ->
    [h1:respond(Conn, Id, Status, Hs, Chunks)];
bodyless_send(Conn, Id, Status, Hs, stream, Chunks) ->
    [h1:send_response(Conn, Id, Status, Hs)
     | [h1:send_data(Conn, Id, C, false) || Status >= 200, C <- Chunks]]
    ++ [h1:send_data(Conn, Id, <<>>, true) || Status >= 200];
bodyless_send(Conn, Id, Status, Hs, stream_trailers, Chunks) ->
    [h1:send_response(Conn, Id, Status, Hs)
     | [h1:send_data(Conn, Id, C, false) || Status >= 200, C <- Chunks]]
    ++ [h1:send_trailers(Conn, Id, [{<<"x-t">>, <<"1">>}]) || Status >= 200].

%% The second request goes out once the handler has finished every send for
%% the first, so all of the first response is already on the wire.
bodyless_exchange(Port, {Method, _, _, _, _} = Case) ->
    Enc = base64:encode(term_to_binary({self(), Case}),
                        #{mode => urlsafe, padding => false}),
    {ok, S} = gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}]),
    try
        ok = gen_tcp:send(S, [Method, " /case/", Enc,
                              " HTTP/1.1\r\nhost: x\r\n\r\n"]),
        receive
            {bodyless_sent, Results} ->
                true = lists:all(fun(R) -> R =:= ok end, Results)
        after 5000 -> error(handler_timeout)
        end,
        ok = gen_tcp:send(S, "GET /next HTTP/1.1\r\nhost: x\r\n"
                             "connection: close\r\n\r\n"),
        bodyless_recv_all(S, <<>>)
    after
        gen_tcp:close(S)
    end.

bodyless_recv_all(S, Acc) ->
    case gen_tcp:recv(S, 0, 5000) of
        {ok, D} -> bodyless_recv_all(S, <<Acc/binary, D/binary>>);
        {error, closed} -> Acc;
        {error, R} -> {error, R, Acc}
    end.

-define(NEXT_CLOSE,
        "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok").

bodyless_check({Method, Status, _Path, Chunks, _Framing}, Bin) when is_binary(Bin) ->
    Next = <<?NEXT_CLOSE>>,
    case binary:longest_common_suffix([Bin, Next]) =:= byte_size(Next) of
        false -> false;
        true ->
            First = binary:part(Bin, 0, byte_size(Bin) - byte_size(Next)),
            case Status < 200 of
                true ->
                    {Interim, Rest} = bodyless_split(First),
                    bodyless_response_ok(Method, Status, Interim, <<>>, <<>>)
                        andalso bodyless_one(Method, 200, Rest, <<"f">>);
                false ->
                    bodyless_one(Method, Status, First,
                                 iolist_to_binary(Chunks))
            end
    end;
bodyless_check(_Case, _Other) ->
    false.

bodyless_one(Method, Status, Bin, Body) ->
    {Head, Rest} = bodyless_split(Bin),
    bodyless_response_ok(Method, Status, Head, Rest, Body).

bodyless_split(Bin) ->
    [Head, Rest] = binary:split(Bin, <<"\r\n\r\n">>),
    {Head, Rest}.

bodyless_response_ok(Method, Status, Head, Rest, Body) ->
    [StatusLine | Lines] = binary:split(Head, <<"\r\n">>, [global]),
    Names = [h1_parse_erl:to_lower(hd(binary:split(L, <<":">>))) || L <- Lines],
    HasTE = lists:member(<<"transfer-encoding">>, Names),
    HasCL = lists:member(<<"content-length">>, Names),
    StatusOk = binary:part(StatusLine, 9, 3) =:= integer_to_binary(Status),
    Bodyless = Method =:= <<"HEAD">> orelse Status < 200
               orelse Status =:= 204 orelse Status =:= 304,
    StatusOk andalso
        case Bodyless of
            true ->
                not HasTE
                    andalso not (HasCL andalso (Status < 200 orelse Status =:= 204))
                    andalso Rest =:= <<>>;
            false ->
                bodyless_decode(Method, <<Head/binary, "\r\n\r\n", Rest/binary>>)
                    =:= {ok, Body}
        end.

%% Parse a framed response with the client parser and require that it
%% consumes exactly the bytes given.
bodyless_decode(Method, Bin) ->
    P = h1_parse:parser([response, {method, Method}]),
    bodyless_drain(h1_parse:execute(P, Bin), []).

bodyless_drain({response, _, _, _, P}, Acc) -> bodyless_drain(h1_parse:execute(P), Acc);
bodyless_drain({header, _, P}, Acc) -> bodyless_drain(h1_parse:execute(P), Acc);
bodyless_drain({headers_complete, P}, Acc) -> bodyless_drain(h1_parse:execute(P), Acc);
bodyless_drain({ok, C, P}, Acc) -> bodyless_drain(h1_parse:execute(P), [C | Acc]);
bodyless_drain({trailer, _, P}, Acc) -> bodyless_drain(h1_parse:execute(P), Acc);
bodyless_drain({done, <<>>}, Acc) -> {ok, iolist_to_binary(lists:reverse(Acc))};
bodyless_drain(Other, _Acc) -> {error, Other}.

collect_chunks(Data, Acc) ->
    case h1_parse_erl:parse_chunk(Data) of
        {ok, C, Rest} -> collect_chunks(Rest, [C | Acc]);
        {done, _} -> {ok, lists:reverse(Acc)};
        {more, _} -> {more, Acc};
        {error, R} -> {error, R}
    end.

-endif.
