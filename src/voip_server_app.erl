%%%-------------------------------------------------------------------
%% @doc voip_server public API
%% @end
%%%-------------------------------------------------------------------

-module(voip_server_app).

-behaviour(application).

-include_lib("voip_server/include/voip_server_nodes.hrl").

-export([start/2, stop/1]).

%% Этот коллбэк Erlang вызывает ТОЛЬКО на том узле, который должен стать активным
start(StartType, _StartArgs) ->
    io:format("voip_server_app: starting with type ~p~n", [StartType]),

    %% Шаг 1. Инициализируем Mnesia в зависимости от ситуации
    case StartType of
        normal ->
            case node() of
                ?MASTER_NODE ->
                    ok = voip_server_db:start(); %% Инициализация мастера
                _SlaveNode ->
                    ok = voip_server_db:start_slave() %% Инициализация ведомого (если он стартует первым)
            end;
        {failover, _FailedNode} ->
            io:format("voip_server_app: CRITICAL - Failover triggered!~n"),
            %% База данных уже работает в фоне, нужно просто дождаться таблиц
            ok = voip_server_db:wait_for_tables();
        {takeover, _OldNode} ->
            io:format("voip_server_app: Takeover triggered!~n"),
            ok = voip_server_db:wait_for_tables()
    end,

    %% Шаг 2. Запускаем бизнес-логику (супервизор)
    voip_server_sup:start_link().

% start(normal, _StartArgs) ->
%     case lists:member(node(), ?SLAVE_NODES) of
%         true ->
%             case voip_server_db:start_slave() of
%                 ok -> ok;
%                 {error, Reason} ->
%                     io:format("Mnesia start error: ~p~n", [Reason]),
%                     exit(Reason)
%             end;
%         false ->
%             case voip_server_db:start() of
%                 ok -> ok;
%                 {error, Reason} ->
%                     io:format("Mnesia start error: ~p~n", [Reason]),
%                     exit(Reason)
%             end
%     end,
%     io:format("Mnesia tables: ~p~n", [mnesia:system_info(tables)]),
%     voip_server_sup:start_link();
% start({failover, FailedNode}, _StartArgs) ->
%     io:format("voip_server_app: Failover ~p~n", [FailedNode]),
%     ok;
% start({takeover, OldNode}, _StartArgs) ->
%     io:format("voip_server_app: Takeover ~p~n", [OldNode]),
%     ok.

stop(_State) ->
    ok.

%% internal functions
