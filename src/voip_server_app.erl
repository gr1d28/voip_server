%%%-------------------------------------------------------------------
%% @doc voip_server public API
%% @end
%%%-------------------------------------------------------------------

-module(voip_server_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    voip_server_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
