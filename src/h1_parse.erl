%% @doc HTTP/1.1 parser facade.
%%
%% Dispatches to the pure-Erlang implementation in h1_parse_erl. A future
%% NIF-backed implementation can slot in here without changing call sites.
-module(h1_parse).

%% Streaming API
-export([parser/0, parser/1, execute/1, execute/2, finish/1, get/2]).

%% Stateless API
-export([parse_request/1, parse_request/2]).
-export([parse_response/1, parse_response/2]).
-export([parse_chunk/1, parse_chunk/2, parse_trailers/1]).

-type backend() :: erl | nif.
-export_type([backend/0]).

parser() -> h1_parse_erl:parser().
parser(Opts) -> h1_parse_erl:parser(Opts).

execute(P) -> h1_parse_erl:execute(P).
execute(P, Bin) -> h1_parse_erl:execute(P, Bin).
finish(P) -> h1_parse_erl:finish(P).

get(P, Prop) -> h1_parse_erl:get(P, Prop).

parse_request(Data) -> h1_parse_erl:parse_request(Data).
parse_request(Data, Opts) -> h1_parse_erl:parse_request(Data, Opts).

parse_response(Data) -> h1_parse_erl:parse_response(Data).
parse_response(Data, Opts) -> h1_parse_erl:parse_response(Data, Opts).

parse_chunk(Data) -> h1_parse_erl:parse_chunk(Data).
parse_chunk(Data, Max) -> h1_parse_erl:parse_chunk(Data, Max).

parse_trailers(Data) -> h1_parse_erl:parse_trailers(Data).
