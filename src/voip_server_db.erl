%%%-------------------------------------------------------------------
%%% @doc Модуль управления базой данных VoIP сервера
%%% @end
%%%-------------------------------------------------------------------

-module(voip_server_db).

-compile({parse_transform, ms_transform}).

-include_lib("voip_server/include/voip_server_nodes.hrl").
-include_lib("voip_server/include/voip_server_db.hrl").

-export([start_master/0, start_slave/0, stop/0, table_info/0]).

-export([add_user/4, add_user/5, get_user/2, delete_user/2, list_users/0, update_user_status/3]).
-export([get_registrations/1, get_registrations/2, add_registration/2, delete_registrations/1, clear_registrations/0, count_registrations/1, count_all_registrations/0]).
-export([add_call/1, get_call/1, delete_call/1, get_all_map_CallId_FsmPid/0, count_all_call/0]).
-export([init_table_users/0]).

-export_type([participant_role/0]).

start_master() ->
    io:format("Start master mnesia~n"),

    case mnesia:system_info(is_running) of
        yes ->
            io:format("Mnesia was been started on master ~p~n", [node()]);
        no ->
            mnesia:start(),
            io:format("Start mnesia on master ~p~n", [node()])
    end,
    io:format("Mnesia system info: ~p~n", [mnesia:system_info()]),
    %% Проверка доступности резервных узлов
    AvailableNodes = [Node ||  Node <- ?NODE_LIST, net_adm:ping(Node) =:= pong],
    io:format("Available nodes: ~p~n", [AvailableNodes]),

    %% Проверка локальной schema на наличе таблиц в базе
    ExistTables = mnesia:system_info(tables),
    NotExistTables = ?TABLES_NAME_LIST -- ExistTables,
    io:format("Not exist tables on master: ~p~n", [NotExistTables]),
    case NotExistTables of
        [] ->
            io:format("All tables exist on ~p~n", [node()]),
            ok;
        _ ->
            io:format("Tables not exist in schema ~p~n", [node()]),
            io:format("Sync cluster nodes ~p~n", [[node() | nodes()]]),
            sync_cluster_nodes(AvailableNodes)
    end.

start_slave() ->
    io:format("Start slave mnesia~n"),

    case mnesia:system_info(is_running) of
        yes ->
            io:format("Mnesia was been started on slave ~p~n", [node()]);
        no ->
            mnesia:start(),
            io:format("Start mnesia on slave ~p~n", [node()])
    end,
    io:format("Mnesia system info: ~p~n", [mnesia:system_info()]),
    %% Проверка локальной schema на наличе таблиц в базе
    ExistTables = mnesia:system_info(tables),
    NotExistTables = ?TABLES_NAME_LIST -- ExistTables,
    io:format("Not exist tables on slave: ~p~n", [NotExistTables]),
    case NotExistTables of
        [] ->
            io:format("All tables exist on ~p~n", [node()]);
        _ ->
            io:format("Sync cluster nodes slave ~p~n", [[node() | nodes()]]),
            sync_cluster_nodes_slave()
    end.

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Остановка
stop() ->
    mnesia:stop().

%% @doc Информация о таблицах
-spec table_info() -> [{atom(), non_neg_integer(), non_neg_integer()}].
table_info() ->
    [{Table, mnesia:table_info(Table, size), mnesia:table_info(Table, memory)}
     || Table <- ?TABLES_NAME_LIST, mnesia:table_info(Table, exists)].

%%%===================================================================
%%% User operations
%%%===================================================================

%% @doc Добавление нового пользователя
-spec add_user(binary(), binary(), binary(), user_status()) -> ok | {error, term()}.
add_user(Name, Domain, Password, Status) ->
    add_user(Name, Domain, Password, Status, <<"">>).

-spec add_user(binary(), binary(), binary(), user_status(), binary()) -> ok | {error, term()}.
add_user(Name, Domain, Password, Status, DisplayName) ->
    User = #users{
        name = Name,
        domain = Domain,
        password = Password,
        display_name = DisplayName,
        status = Status
    },
    F = fun() -> mnesia:write(User) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

%% @doc Получение пользователя по name
-spec get_user(binary(), binary()) -> {ok, #users{}} | {error, not_found}.
get_user(Name, Domain) ->
    Pattern = #users{name = Name, domain = Domain, _ = '_'},
    case mnesia:dirty_match_object(users, Pattern) of
        [User] -> {ok, User};
        [] -> {error, not_found}
    end.

%% @doc Удаление пользователя
-spec delete_user(binary(), binary()) -> ok | {error, term()}.
delete_user(Name, Domain) ->
    Pattern = #users{name = Name, domain = Domain, _ = '_'},
    F = fun() ->
        Users = mnesia:match_object(Pattern),
        lists:foreach(fun(Object) -> mnesia:delete_object(Object) end, Users)
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

%% @doc Список всех пользователей
-spec list_users() -> [#users{}].
list_users() ->
    mnesia:dirty_match_object(users, #users{_ = '_'}).

%% @doc Обновление статуса пользователя
-spec update_user_status(binary(), binary(), user_status()) -> ok | {error, term()}.
update_user_status(Name, Domain, NewStatus) ->
    F = fun() ->
        case mnesia:wread({users, {Name, Domain}}) of
            [User] ->
                UpdatedUser = User#users{status = NewStatus},
                mnesia:write(UpdatedUser),
                ok;
            [] ->
                {error, not_found}
        end
    end,
    case mnesia:transaction(F) of
        {atomic, Result} -> Result;
        {aborted, Reason} -> {error, Reason}
    end.

%%%===================================================================
%%% Registration operations
%%%===================================================================

%% @doc Добавление регистрации
-spec add_registration(nksip:aor(), nksip_registrar_lib:reg_contact()) -> ok | {error, term()}.
add_registration(AOR, RegContact) ->
    Reg = #registrations{
        aor = AOR,
        reg_contact = RegContact
    },
    F = fun() -> mnesia:write(Reg) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

%% @doc Получение всех регистраций для AOR
-spec get_registrations(nksip:aor()) -> [#registrations{}].
get_registrations(AOR) ->
    mnesia:dirty_read({registrations, AOR}).

-spec get_registrations(binary(), binary()) -> [#registrations{}].
get_registrations(UserName, Domain) ->
    MatchSpec = [
        {
            #registrations{aor = {'$1', UserName, Domain}, _ = '_'},
            [],
            ['$_']
        }
    ],
    mnesia:dirty_select(registrations, MatchSpec).

%% @doc Удаление всех котактов регистрации по aor
-spec delete_registrations(nksip:aor()) -> ok | {error, term()}.
delete_registrations(AOR) ->
    Pattern = #registrations{aor = AOR, _ = '_'},
    F = fun() ->
        Registrations = mnesia:match_object(Pattern),
        lists:foreach(fun(Object) -> mnesia:delete_object(Object) end, Registrations)
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

%% @doc Очистка всех регистраций
-spec clear_registrations() -> ok | {error, term()}.
clear_registrations() ->
    F = fun() -> mnesia:clear_table(registrations) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

%% @doc Количество регистраций для AOR
-spec count_registrations(nksip:aor()) -> non_neg_integer().
count_registrations(AOR) ->
    length(get_registrations(AOR)).

-spec count_all_registrations() -> non_neg_integer().
count_all_registrations() ->
    length(mnesia:dirty_match_object(registrations, #registrations{_ = '_'})).

%%%===================================================================
%%% Call operations
%%%===================================================================

-spec add_call(#call{}) -> ok | {error, term()}.
add_call(Call) ->
    F = fun() -> mnesia:write(Call) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

-spec get_call(nksip:call_id()) -> [#call{}].
get_call(CallId) ->
    case mnesia:dirty_read({call, CallId}) of
        [] ->
            mnesia:dirty_index_read(call, CallId, call_id_b);
        Call ->
            Call
    end.

-spec delete_call(nksip:call_id()) -> ok | {error, term()}.
delete_call(CallId) ->
    F = fun() ->
        case mnesia:read({call, CallId}) of
            [] ->
                case mnesia:index_read(call, CallId, call_id_b) of
                    [] ->
                        ok;
                    Calls ->
                        lists:foreach(fun(Call) ->
                            mnesia:delete({call, Call#call.call_id_a})
                        end, Calls)
                end;
            [_Call] ->
                mnesia:delete({call, CallId})
        end
    end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

-spec get_all_map_CallId_FsmPid() -> [{nksip:call_id(), nksip:call_id(), pid()}] | [].
get_all_map_CallId_FsmPid() ->
    %% Возвращаем все звонки, кроме завершенных
    MatchSpec = ets:fun2ms(fun(#call{call_id_a = CallIdA, call_id_b = CallIdB,
                                fsm_pid = FsmPid, state = State})
                             when State /= terminated ->
                                  {CallIdA, CallIdB, FsmPid}
                           end),
    mnesia:dirty_select(call, MatchSpec).

-spec count_all_call() -> non_neg_integer().
count_all_call() ->
    length(mnesia:dirty_match_object(call, #call{_ = '_'})). %% TODO добавить проверку результата во все подобные функции

%%%===================================================================
%%% Internal functions
%%%===================================================================

init_table_users() ->
    Hash1 = nksip_auth:make_ha1(<<"100">>, <<"1234">>, <<"172.40.0.2">>),
    Hash2 = nksip_auth:make_ha1(<<"101">>, <<"1234">>, <<"172.40.0.2">>),
    Hash3 = nksip_auth:make_ha1(<<"102">>, <<"1234">>, <<"172.40.0.2">>),
    Hash4 = nksip_auth:make_ha1(<<"103">>, <<"1234">>, <<"172.40.0.2">>),
    add_user(<<"100">>, <<"172.40.0.2">>, Hash1, active, <<"DisplayName">>),
    add_user(<<"101">>, <<"172.40.0.2">>, Hash2, active, <<"DisplayName">>),
    add_user(<<"102">>, <<"172.40.0.2">>, Hash3, active, <<"DisplayName">>),
    add_user(<<"103">>, <<"172.40.0.2">>, Hash4, active, <<"DisplayName">>).

%% Запускается на master при первой загрузке системы
sync_cluster_nodes(NodeList) ->
    %% Остановка mnesia на всех доступных узлах
    lists:foreach(fun(Node) ->
        case rpc:call(Node, mnesia, stop, []) of
            stopped ->
                io:format("Stop mnesia on ~p~n", [Node]);
            {error, Reason1} ->
                io:format("Error in stop mnesia on ~p: ~p~n", [Node, Reason1])
        end
    end, NodeList),

    %% Удаление дефолтных schema
    lists:foreach(fun(Node) ->
        case rpc:call(Node, mnesia, delete_schema, [[Node]]) of
            ok ->
                io:format("Delete schema on ~p~n", [Node]);
            {error, Reason2} ->
                io:format("Error in delete schema on ~p: ~p~n", [Node, Reason2])
        end
    end, NodeList),

    %% Создание schema на master с включением всех доступных узлов
    case mnesia:create_schema(NodeList) of
        ok ->
            io:format("Create schema on master node ~p~n", [node()]);
        {error, Reason3} ->
            io:format("Error in create schema on master node ~p: ~p~n", [node(), Reason3])
    end,

    %% Запуск mnesia на всех узлах с новой schema
    lists:foreach(fun(Node) ->
        case rpc:call(Node, mnesia, start, []) of
            ok ->
                io:format("Start mnesia on ~p~n", [Node]);
            {error, Reason4} ->
                io:format("Error in start mnesia on ~p: ~p~n", [Node, Reason4])
        end
    end, NodeList),

    AvailableNodes = mnesia:system_info(running_db_nodes),
    case ?NODE_LIST -- AvailableNodes of
        %% Все узлы запустились в кластере
        [] ->
            io:format("All nodes ready to create table~n"),
            ResultList = [mnesia:create_table(Table, get_table_opts(Table, AvailableNodes)) || Table <- ?TABLES_NAME_LIST],
            case proplists:get_all_values(aborted, ResultList) of
                %% Нет ошибок при добавлении таблиц
                [] ->
                    io:format("Tables ~p created on nodes ~p~n", [?TABLES_NAME_LIST, AvailableNodes]),
                    ok;
                ErrorList ->
                    io:format("Error: Tables not created with reasons: ~p~n", [ErrorList]),
                    {error, tables_not_created}
            end;
        DiffList ->
            io:format("Error: Not all available nodes have launched mnesia: ~p~n", [DiffList]),
            {error, not_all_launched}
    end.

%% @private Получить опции для создания таблицы
get_table_opts(Table, AvailableNodes) ->
    case Table of
        users ->
            [{type, set}, {disc_copies, AvailableNodes}, {record_name, users},
             {attributes, record_info(fields, users)}, {index, [domain]}];
        registrations ->
            [{type, bag}, {disc_copies, AvailableNodes}, {record_name, registrations},
             {attributes, record_info(fields, registrations)}];
        call ->
            [{type, set}, {disc_copies, AvailableNodes}, {record_name, call},
             {attributes, record_info(fields, call)}, {index, [call_id_b]}];
        dialplan ->
            [{type, set}, {disc_copies, AvailableNodes}, {record_name, dialplan},
             {attributes, record_info(fields, dialplan)}]
    end.

sync_cluster_nodes_slave() ->
    io:format("Call sync_cluster_nodes_slave on node ~p~n", [node()]),
    sync_cluster_nodes_slave(30),
    io:format("Slave continue~n").

sync_cluster_nodes_slave(0) ->
    io:format("Slave not end~n"),
    ok;
sync_cluster_nodes_slave(Times) ->
    case mnesia:system_info(running_db_nodes) of
        ?NODE_LIST ->
            ok;
        List ->
            io:format("Exist nodes: ~p~n", [List]),
            timer:sleep(1000),
            sync_cluster_nodes_slave(Times - 1)
    end.
