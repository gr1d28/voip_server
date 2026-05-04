%%%-------------------------------------------------------------------
%% @doc voip_server public API
%% @end
%%%-------------------------------------------------------------------

-module(voip_server_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case voip_server_db:start() of
        ok -> ok;
        {error, Reason} ->
            io:format("Mnesia start error: ~p~n", [Reason]),
            exit(Reason)
    end,
    io:format("Mnesia tables: ~p~n", [mnesia:system_info(tables)]),
    voip_server_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
