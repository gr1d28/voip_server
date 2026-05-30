%%%-------------------------------------------------------------------
%% @doc voip_server public API
%% @end
%%%-------------------------------------------------------------------

-module(voip_server_app).

-behaviour(application).

-include_lib("voip_server/include/voip_server_nodes.hrl").

-export([start/0, stop/0]).
-export([start/2, stop/1]).
-export([is_active/0, get_role/0]).

start() ->
    application:start(voip_server).

stop() ->
    application:stop(voip_server).

start(StartType, _StartArgs) ->
    io:format("voip_server_app: starting with type ~p on node ~p~n", [StartType, node()]),

    ShouldStart = case StartType of
        normal ->
            node() =:= ?MASTER_NODE;
        {failover, FailedNode} ->
            io:format("Failover from ~p, becoming active~n", [FailedNode]),
            true;
        {takeover, OldNode} ->
            io:format("Takeover from ~p, becoming active~n", [OldNode]),
            true;
        _ ->
            false
    end,

    case ShouldStart of
        true ->
            %% Становимся активным узлом
            application:set_env(voip_server, role, active),
            io:format("Starting ACTIVE mode on ~p~n", [node()]),

            %% Запускаем бизнес-логику
            {ok, Pid} = voip_server_sup:start_link(),

            %% Регистрируемся как активный процесс
            global:register_name(voip_server_active, self()),

            %% Запускаем мониторинг slave узлов
            spawn(fun() -> monitor_slaves() end),

            {ok, Pid};
        false ->
            %% Пассивный режим - приложение не запускает бизнес-логику
            io:format("PASSIVE mode on ~p - application not started~n", [node()]),
            {ok, self()}
    end.

stop(_State) ->
    io:format("voip_server_app: stopping on node ~p~n", [node()]),
    %% Очищаем глобальную регистрацию
    global:unregister_name(voip_server_active),
    ok.

%% @doc Проверка, активен ли текущий узел
-spec is_active() -> boolean().
is_active() ->
    case application:get_env(voip_server, role) of
        {ok, active} -> true;
        _ -> false
    end.

%% @doc Получить роль текущего узла
-spec get_role() -> active | passive.
get_role() ->
    case application:get_env(voip_server, role) of
        {ok, active} -> active;
        _ -> passive
    end.

%% internal functions

%% @private Мониторинг slave узлов для предотвращения двойной активации
monitor_slaves() ->
    %% Мониторим все slave узлы
    lists:foreach(fun(Node) ->
        erlang:monitor_node(Node, true)
    end, ?SLAVE_NODES),

    receive
        {'DOWN', _Ref, process, _Pid, _Reason} ->
            %% Процесс умер, выходим
            ok;
        {nodedown, Node} ->
            io:format("Node ~p went down~n", [Node]),
            monitor_slaves()
    end.
