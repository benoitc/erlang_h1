%% Copyright (c) 2026 Benoit Chesneau.
%% SPDX-License-Identifier: Apache-2.0
%%
-module(h1_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    h1_sup:start_link().

stop(_State) ->
    ok.
