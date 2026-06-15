%%%-------------------------------------------------------------------
%% @doc voip_server public API
%% @end
%%%-------------------------------------------------------------------

-module(voip_server_app).

-behaviour(application).

-include_lib("voip_server/include/voip_server_nodes.hrl").

-export([start/0, stop/0]).
-export([start/2, stop/1]).

start() ->
    application:start(voip_server).

stop() ->
    application:stop(voip_server).

start(StartType, _StartArgs) ->
    io:format("voip_server_app: starting with type ~p on node ~p~n", [StartType, node()]),
    io:format("~p~n", [mnesia:system_info()]),
    voip_server_sup:start_link().

stop(_State) ->
    io:format("voip_server_app: stopping on node ~p~n", [node()]),
    ok.
