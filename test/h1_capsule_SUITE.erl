%%% @doc Capsule codec tests (mirrors erlang_h2's h2_capsule_SUITE).
-module(h1_capsule_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0]).
-export([
    encode_decode_datagram/1,
    encode_numeric_type/1,
    decode_incomplete/1,
    decode_all_sequence/1,
    decode_all_partial/1,
    empty_payload/1,
    large_type/1,
    large_payload/1,
    cross_protocol_format/1
]).

all() ->
    [encode_decode_datagram, encode_numeric_type, decode_incomplete,
     decode_all_sequence, decode_all_partial, empty_payload,
     large_type, large_payload, cross_protocol_format].

encode_decode_datagram(_C) ->
    Enc = h1_capsule:encode(datagram, <<"hello">>),
    {ok, {datagram, <<"hello">>}, <<>>} = h1_capsule:decode(Enc).

encode_numeric_type(_C) ->
    Enc = h1_capsule:encode(16#42, <<"payload">>),
    {ok, {16#42, <<"payload">>}, <<>>} = h1_capsule:decode(Enc).

decode_incomplete(_C) ->
    ?assertMatch({more, _}, h1_capsule:decode(<<0>>)),
    ?assertMatch({more, _}, h1_capsule:decode(<<0, 10>>)),
    ?assertMatch({more, _}, h1_capsule:decode(<<0, 10, 1, 2>>)).

decode_all_sequence(_C) ->
    A = h1_capsule:encode(datagram, <<"one">>),
    B = h1_capsule:encode(datagram, <<"two">>),
    C = h1_capsule:encode(datagram, <<"three">>),
    {ok, [{datagram, <<"one">>},
          {datagram, <<"two">>},
          {datagram, <<"three">>}], <<>>} =
        h1_capsule:decode_all(<<A/binary, B/binary, C/binary>>).

decode_all_partial(_C) ->
    A = h1_capsule:encode(datagram, <<"one">>),
    {ok, [{datagram, <<"one">>}], <<0, 10, 1, 2, 3>>} =
        h1_capsule:decode_all(<<A/binary, 0, 10, 1, 2, 3>>).

empty_payload(_C) ->
    Enc = h1_capsule:encode(datagram, <<>>),
    {ok, {datagram, <<>>}, <<>>} = h1_capsule:decode(Enc).

large_type(_C) ->
    Enc = h1_capsule:encode(16#12345678, <<"x">>),
    {ok, {16#12345678, <<"x">>}, <<>>} = h1_capsule:decode(Enc).

large_payload(_C) ->
    Payload = binary:copy(<<"x">>, 4096),
    Enc = h1_capsule:encode(datagram, Payload),
    {ok, {datagram, Payload}, <<>>} = h1_capsule:decode(Enc).

cross_protocol_format(_C) ->
    %% h1_capsule must produce bytes identical to h2_capsule for the same
    %% inputs — that's the whole point of the module being a thin copy.
    %% We don't have erlang_h2 as a dep here, so we verify the hardcoded
    %% expected bytes for a couple of datagrams.
    ?assertEqual(<<0, 5, "hello">>, h1_capsule:encode(datagram, <<"hello">>)),
    ?assertEqual(<<0, 0>>, h1_capsule:encode(datagram, <<>>)),
    %% A type requiring 2-byte varint encoding (0x40 | type-high-byte).
    ?assertEqual(<<64, 100, 3, "abc">>,
                 h1_capsule:encode(16#64, <<"abc">>)).
