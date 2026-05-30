%%%-------------------------------------------------------------------
%%% @doc Модуль управления базой данных VoIP сервера
%%% @end
%%%-------------------------------------------------------------------

-module(voip_server_db).

-compile({parse_transform, ms_transform}).

-include_lib("voip_server/include/voip_server_nodes.hrl").
-include_lib("voip_server/include/voip_server_db.hrl").

-export([start_replication/0, start/0, start_slave/0, stop/0]).
-export([ensure_cluster/0, wait_for_tables/0, table_info/0]).

-export([add_user/4, add_user/5, get_user/2, delete_user/2, list_users/0, update_user_status/3]).
-export([get_registrations/1, get_registrations/2, add_registration/2, delete_registrations/1, clear_registrations/0, count_registrations/1, count_all_registrations/0]).
-export([add_call/1, get_call/1, delete_call/1, get_all_map_CallId_FsmPid/0, count_all_call/0]).
-export([init_table_users/0]).

-export_type([participant_role/0]).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Запуск репликации на узле (вызывается на всех узлах)
-spec start_replication() -> ok | {error, term()}.
start_replication() ->
    io:format("Starting Mnesia replication on ~p~n", [node()]),
    voip_server_mnesia:ensure_replication().

%% @doc Запуск на мастере (создание таблиц)
-spec start() -> ok | {error, term()}.
start() ->
    io:format("Starting Mnesia on master ~p~n", [node()]),
    ensure_cluster(),
    start_replication().

%% @doc Запуск на слейве (только репликация)
-spec start_slave() -> ok | {error, term()}.
start_slave() ->
    io:format("Starting Mnesia replication on slave ~p~n", [node()]),
    start_replication().

%% @doc Обеспечить наличие кластера
ensure_cluster() ->
    case mnesia:system_info(is_running) of
        yes -> ok;
        no ->
            mnesia:start(),
            timer:sleep(1000)
    end,

    %% Проверяем схему
    SchemaNodes = mnesia:system_info(db_nodes),
    case lists:member(node(), SchemaNodes) of
        true -> ok;
        false ->
            io:format("Adding current node to schema~n"),
            mnesia:change_table_copy_type(schema, node(), disc_copies)
    end.

%% @doc Ожидание таблиц
wait_for_tables() ->
    voip_server_mnesia:wait_for_sync(30000).

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
    mnesia:dirty_read({call, CallId}).

-spec delete_call(nksip:call_id()) -> ok | {error, term()}.
delete_call(CallId) ->
    F = fun () -> mnesia:delete({call, CallId}) end,
    case mnesia:transaction(F) of
        {atomic, ok} -> ok;
        {aborted, Reason} -> {error, Reason}
    end.

-spec get_all_map_CallId_FsmPid() -> [{nksip:call_id(), pid()}] | [].
get_all_map_CallId_FsmPid() ->
    %% Возвращаем все звонки, кроме завершенных
    MatchSpec = ets:fun2ms(fun(#call{call_id = CallId, fsm_pid = FsmPid, state = State})
                             when State /= terminated ->
                                  {CallId, FsmPid}
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
