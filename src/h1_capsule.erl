%% @doc RFC 9297 Capsule Protocol codec over a byte stream.
%%
%% Capsules convey control information inside any HTTP tunnel. Format:
%%
%%   +------------+------------+
%%   | Type (i)   | Length (i) |
%%   +------------+------------+
%%   | Payload (*)             |
%%   +-------------------------+
%%
%% Type and Length are QUIC variable-length integers (RFC 9000 section 16).
%%
%% This module is a pure codec: it owns no socket. Callers (including
%% masque-over-H1) drive reads/writes themselves, feeding bytes in and
%% retrieving capsules out. Identical wire format to h2_capsule and
%% quic_h3_capsule so the three modules are interchangeable at the
%% byte-stream level.
-module(h1_capsule).

-export([encode/2, decode/1, decode_all/1]).
-export([encode_type/1, decode_type/1]).
-export([datagram/1]).

%% Standard Capsule Types (RFC 9297 + extensions).
-define(DATAGRAM, 16#00).

-type capsule_type() :: non_neg_integer() | atom().
-type capsule() :: {Type :: capsule_type(), Payload :: binary()}.

-export_type([capsule_type/0, capsule/0]).

%% ----------------------------------------------------------------------------
%% Constructors
%% ----------------------------------------------------------------------------

-spec datagram(binary()) -> capsule().
datagram(Payload) ->
    {datagram, Payload}.

%% ----------------------------------------------------------------------------
%% Encoding
%% ----------------------------------------------------------------------------

-spec encode(capsule_type(), binary()) -> binary().
encode(Type, Payload) when is_atom(Type) ->
    encode(encode_type(Type), Payload);
encode(Type, Payload) when is_integer(Type) ->
    TypeBin = h1_varint:encode(Type),
    LengthBin = h1_varint:encode(byte_size(Payload)),
    <<TypeBin/binary, LengthBin/binary, Payload/binary>>.

-spec encode_type(atom()) -> non_neg_integer().
encode_type(datagram) -> ?DATAGRAM.

%% ----------------------------------------------------------------------------
%% Decoding
%% ----------------------------------------------------------------------------

-spec decode(binary()) -> {ok, capsule(), binary()} | {more, pos_integer()} | {error, term()}.
decode(Bin) ->
    case h1_varint:decode(Bin) of
        {error, incomplete} ->
            {more, 1};
        {ok, Type, Rest1} ->
            case h1_varint:decode(Rest1) of
                {error, incomplete} ->
                    {more, 1};
                {ok, Length, Rest2} ->
                    PayloadSize = byte_size(Rest2),
                    if
                        PayloadSize >= Length ->
                            <<Payload:Length/binary, Rest/binary>> = Rest2,
                            {ok, {decode_type(Type), Payload}, Rest};
                        true ->
                            {more, Length - PayloadSize}
                    end
            end
    end.

-spec decode_type(non_neg_integer()) -> non_neg_integer() | atom().
decode_type(?DATAGRAM) -> datagram;
decode_type(N) -> N.

-spec decode_all(binary()) -> {ok, [capsule()], binary()}.
decode_all(Bin) ->
    decode_all(Bin, []).

decode_all(<<>>, Acc) ->
    {ok, lists:reverse(Acc), <<>>};
decode_all(Bin, Acc) ->
    case decode(Bin) of
        {ok, Capsule, Rest} ->
            decode_all(Rest, [Capsule | Acc]);
        {more, _N} ->
            {ok, lists:reverse(Acc), Bin}
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

encode_decode_test() ->
    Payload = <<"test payload">>,
    Encoded = encode(datagram, Payload),
    {ok, Decoded, <<>>} = decode(Encoded),
    ?assertEqual({datagram, Payload}, Decoded).

encode_numeric_type_test() ->
    Encoded = encode(16#1234, <<"custom">>),
    {ok, {16#1234, <<"custom">>}, <<>>} = decode(Encoded).

decode_incomplete_test() ->
    ?assertMatch({more, _}, decode(<<0>>)),
    ?assertMatch({more, _}, decode(<<0, 5>>)).

decode_all_test() ->
    C1 = encode(datagram, <<"one">>),
    C2 = encode(datagram, <<"two">>),
    C3 = encode(datagram, <<"three">>),
    {ok, Capsules, <<>>} = decode_all(<<C1/binary, C2/binary, C3/binary>>),
    ?assertEqual([{datagram, <<"one">>},
                  {datagram, <<"two">>},
                  {datagram, <<"three">>}], Capsules).

decode_all_partial_test() ->
    C1 = encode(datagram, <<"one">>),
    {ok, [{datagram, <<"one">>}], <<0, 10, 1, 2, 3>>} =
        decode_all(<<C1/binary, 0, 10, 1, 2, 3>>).

empty_payload_test() ->
    {ok, {datagram, <<>>}, <<>>} = decode(encode(datagram, <<>>)).

large_type_test() ->
    LargeType = 16#12345678,
    Encoded = encode(LargeType, <<"x">>),
    {ok, {LargeType, <<"x">>}, <<>>} = decode(Encoded).

large_payload_test() ->
    Payload = binary:copy(<<"x">>, 100),
    Encoded = encode(datagram, Payload),
    {ok, {datagram, Payload}, <<>>} = decode(Encoded).

-endif.
