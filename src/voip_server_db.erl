%%%-------------------------------------------------------------------
%%% @doc Модуль управления базой данных VoIP сервера
%%% @end
%%%-------------------------------------------------------------------

-module(voip_server_db).

-compile({parse_transform, ms_transform}).

-include_lib("voip_server/include/voip_server_nodes.hrl").
-include_lib("voip_server/include/voip_server_db.hrl").

-export([start/0, start_slave/0, stop/0, create_tables/0, create_tables/1]).
-export([ensure_tables/0, table_info/0, clear_all/0]).

-export([add_user/4, add_user/5, get_user/2, delete_user/2, list_users/0, update_user_status/3]).
-export([get_registrations/1, get_registrations/2, add_registration/2, delete_registrations/1, clear_registrations/0, count_registrations/1, count_all_registrations/0]).
-export([add_call/1, get_call/1, delete_call/1, get_all_map_CallId_FsmPid/0, count_all_call/0]).
-export([init_table_users/0]).

-export_type([participant_role/0]).

%%%===================================================================
%%% API functions
%%%===================================================================

%% @doc Запуск и инициализация БД
-spec start() -> ok | {error, term()}.
start() ->
    case mnesia:system_info(is_running) of
        yes ->
            ExistingTables = mnesia:system_info(tables),
            TablesCount = length(ExistingTables),
            if
                TablesCount =:= 1 ->
                    mnesia:stop(),
                    io:format("mnesia stop and start_local()~n"),
                    start_local();
                TablesCount =/= ?COUNT_TABLES ->
                    ensure_tables();
                true ->
                    io:format("voip_server_db: all tables exist~n"),
                    ok
            end;
        no ->
            start_local()
    end.

start_slave() ->
    %% 1. Ждем, пока на мастере не просто поднимется сеть, а СТАРТУЕТ MNESIA
    % ok = wait_for_master_mnesia(?MASTER_NODE, 15), %% 15 попыток

    %% 2. Запускаем локальную mnesia с ЧИСТОЙ директорией (схема в RAM)
    application:ensure_all_started(mnesia),

    %% 3. Подключаемся к работающей базе мастера
    case mnesia:change_config(extra_db_nodes, [?MASTER_NODE]) of
        {ok, [?MASTER_NODE]} ->
            io:format("Connected to master Mnesia cluster.~n"),
            %% 4. Делаем свою локальную схему дисковой
            case mnesia:change_table_copy_type(schema, node(), disc_copies) of
                {atomic, ok} ->
                    %% 5. Копируем таблицы с мастера к себе на диск
                    ok = copy_tables_from_master(?MASTER_NODE);
                {aborted, {already_exists, schema, _, disc_copies}} ->
                    io:format("voip_server_db: schema already_exist~n"),
                    %% Если схема уже была дисковой (перезапуск слейва)
                    ok = copy_tables_from_master(?MASTER_NODE);
                {aborted, Reason} ->
                    {error, {schema_copy_failed, Reason}}
            end;
        {ok, []} ->
            %% Мы уже были подключены или мастер не отдал конфигурацию
            wait_for_tables();
        {error, Reason} ->
            {error, {connect_to_cluster_failed, Reason}}
    end.

%% @doc Остановка БД
-spec stop() -> ok | {error, term()}.
stop() ->
    mnesia:stop().

%% @doc Локальный запуск mnesia
-spec start_local() -> ok | {error, term()}.
start_local() ->
    case mnesia:system_info(use_dir) of
        true ->
            io:format("Schema already exists on disk. Starting Mnesia...~n"),
            case mnesia:start() of
                ok ->
                    wait_for_tables();
                {error, Reason} ->
                    io:format("Error starting Mnesia: ~p~n", [Reason]),
                    {error, Reason}
            end;
        false ->
            io:format("First run. Creating new schema...~n"),
            mnesia:stop(),
            case mnesia:create_schema([node()]) of
                ok ->
                    ok = mnesia:start(),
                    ok = create_tables(),
                    wait_for_tables();
                {error, Error} ->
                    io:format("Error creating schema: ~p~n", [Error]),
                    {error, Error}
            end
    end.

%% @doc Создание всех таблиц на текущем узле
-spec create_tables() -> ok | {error, term()}.
create_tables() ->
    create_tables([node()]).

%% @doc Создание всех таблиц на указанных узлах
-spec create_tables([node()]) -> ok | {error, term()}.
create_tables(Nodes) ->
    io:format("create_tables(~p)~n", [Nodes]),

    Tables = [
        {users, [
            {type, set},
            {disc_copies, Nodes},
            {record_name, users},
            {attributes, record_info(fields, users)},
            {index, [domain]}
        ]},
        {registrations, [
            {type, bag},        %% один AOR может иметь несколько контактов
            {disc_copies, Nodes},
            {record_name, registrations},
            {attributes, record_info(fields, registrations)}
        ]},
        {call, [
            {type, set},
            {disc_copies, Nodes},
            {record_name, call},
            {attributes, record_info(fields, call)}
        ]},
        {dialplan, [
            {type, set},
            {disc_copies, Nodes},
            {record_name, dialplan},
            {attributes, record_info(fields, dialplan)}
        ]}
    ],

    Results = [create_table(Name, Opts) || {Name, Opts} <- Tables],

    case lists:all(fun(Result) -> Result =:= ok end, Results) of
        true -> ok;
        false -> {error, table_creation_failed}
    end.

%% @doc Проверка и создание таблиц если их нет (для hot-загрузки)
-spec ensure_tables() -> ok.
ensure_tables() ->
    io:format("ensure table~n"),
    Tables = ?TABLES_NAME_LIST,
    lists:foreach(fun ensure_table/1, Tables).

%% @doc Информация о таблицах
-spec table_info() -> [{atom(), non_neg_integer(), non_neg_integer()}].
table_info() ->
    [{Table, mnesia:table_info(Table, size), mnesia:table_info(Table, memory)}
     || Table <- ?TABLES_NAME_LIST, mnesia:table_info(Table, exists)].

%% @doc Очистка всех данных из таблиц
-spec clear_all() -> ok | {error, term()}.
clear_all() ->
    F = fun() ->
        [mnesia:delete_table(TableName) || TableName <- ?TABLES_NAME_LIST]
    end,
    case mnesia:transaction(F) of
        {atomic, _} ->
            create_tables(),
            ok;
        Error ->
            Error
    end.

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

%% @private Создание одной таблицы
-spec create_table(atom(), [tuple()]) -> ok | {error, term()}.
create_table(Name, Opts) ->
    io:format("create table: ~p ~p~n", [Name, Opts]),
    case mnesia:create_table(Name, Opts) of
        {atomic, ok} -> ok;
        {aborted, {already_exists, _}} -> ok;
        Error -> Error
    end.

%% @private Проверка существования таблицы
-spec ensure_table(atom()) -> ok.
ensure_table(Table) ->
    io:format("ensure table (~p)~n", [Table]),
    ExistTables = mnesia:system_info(tables),
    case lists:member(Table, ExistTables) of
        true -> ok;
        false ->
            create_table(Table, table_opts(Table))
            %% init_table(Table)
    end.

%% @private Параметры таблиц по умолчанию
-spec table_opts(atom()) -> [tuple()].
table_opts(users) ->
    [{type, set}, {disc_copies, [node()]}, {record_name, users},
     {attributes, record_info(fields, users)}];
table_opts(registrations) ->
    [{type, bag}, {disc_copies, [node()]}, {record_name, registrations},
     {attributes, record_info(fields, registrations)}];
table_opts(call) ->
    [{type, set}, {disc_copies, [node()]}, {record_name, call},
     {attributes, record_info(fields, call)}];
table_opts(dialplan) ->
    [{type, set}, {disc_copies, [node()]}, {record_name, dialplan},
     {attributes, record_info(fields, dialplan)}].

init_table_users() ->
    Hash1 = nksip_auth:make_ha1(<<"100">>, <<"1234">>, <<"172.40.0.2">>),
    Hash2 = nksip_auth:make_ha1(<<"101">>, <<"1234">>, <<"172.40.0.2">>),
    Hash3 = nksip_auth:make_ha1(<<"102">>, <<"1234">>, <<"172.40.0.2">>),
    Hash4 = nksip_auth:make_ha1(<<"103">>, <<"1234">>, <<"172.40.0.2">>),
    add_user(<<"100">>, <<"172.40.0.2">>, Hash1, active, <<"DisplayName">>),
    add_user(<<"101">>, <<"172.40.0.2">>, Hash2, active, <<"DisplayName">>),
    add_user(<<"102">>, <<"172.40.0.2">>, Hash3, active, <<"DisplayName">>),
    add_user(<<"103">>, <<"172.40.0.2">>, Hash4, active, <<"DisplayName">>).

% %% Цикл ожидания полной готовности Mnesia на мастере
% wait_for_master_mnesia(_Master, 0) ->
%     {error, master_mnesia_timeout};
% wait_for_master_mnesia(Master, Retries) ->
%     %% Сначала пингуем ноду, чтобы Erlang установил соединение
%     net_adm:ping(Master),
%     %% Делаем RPC-вызов к Mnesia на мастере, чтобы узнать её статус
%     case rpc:call(Master, mnesia, system_info, [is_running]) of
%         yes ->
%             %% Mnesia на мастере запущена
%             %% Ждем еще 1 секунду, чтобы гарантированно завершился voip_server_db:start() и создались таблицы
%             timer:sleep(1000),
%             io:format("Master Mnesia is YES and ready.~n"),
%             ok;
%         _NotReady ->
%             %% Возвращает 'no', 'starting' или {badrpc, _} если мастер еще лежит
%             io:format("Master Mnesia not ready yet (retries left: ~p)...~n", [Retries]),
%             timer:sleep(2000), %% Ждем 2 секунды перед следующей проверкой
%             wait_for_master_mnesia(Master, Retries - 1)
%     end.

%% Автоматическое копирование всех нужных таблиц
copy_tables_from_master(_MasterNode) ->
    Tables = ?TABLES_NAME_LIST,
    lists:foreach(fun(Table) ->
        case mnesia:add_table_copy(Table, node(), disc_copies) of
            {atomic, ok} -> io:format("Table ~p copied.~n", [Table]);
            {aborted, {already_exists, _, _}} -> ok; %% Таблица уже есть
            {aborted, Reason} -> exit({copy_table_failed, Table, Reason})
        end
    end, Tables),
    wait_for_tables().

wait_for_tables() ->
    case mnesia:wait_for_tables(?TABLES_NAME_LIST, 15000) of
        ok -> ok;
        {error, R} -> {error, {wait_tables_failed, R}}
    end.
