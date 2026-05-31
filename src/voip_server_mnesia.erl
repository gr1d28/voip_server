-module(voip_server_mnesia).

-include_lib("voip_server/include/voip_server_nodes.hrl").
-include_lib("voip_server/include/voip_server_db.hrl").

-export([ensure_replication/0, setup_cluster/0]).
-export([wait_for_sync/1, create_master_tables/0]).

%% @doc Установка кластера с нуля
-spec setup_cluster() -> ok.
setup_cluster() ->
    io:format("Setting up Mnesia cluster~n"),
    
    %% Останавливаем Mnesia на всех узлах
    lists:foreach(fun(Node) ->
        case rpc:call(Node, mnesia, system_info, [is_running]) of
            yes -> 
                io:format("Stopping Mnesia on ~p~n", [Node]),
                rpc:call(Node, mnesia, stop, []);
            _ -> 
                ok
        end
    end, ?NODE_LIST),
    
    timer:sleep(1000),
    
    %% Удаляем старую схему
    lists:foreach(fun(Node) ->
        io:format("Deleting schema on ~p~n", [Node]),
        rpc:call(Node, mnesia, delete_schema, [[Node]])
    end, ?NODE_LIST),
    
    timer:sleep(2000),
    
    %% Создаем схему на всех узлах
    io:format("Creating schema on all nodes~n"),
    rpc:call(?MASTER_NODE, mnesia, create_schema, [?NODE_LIST]),
    
    timer:sleep(2000),
    
    %% Запускаем Mnesia на всех узлах
    lists:foreach(fun(Node) ->
        io:format("Starting Mnesia on ~p~n", [Node]),
        rpc:call(Node, mnesia, start, [])
    end, ?NODE_LIST),
    
    timer:sleep(2000),
    
    %% Создаём таблицы на master узле
    io:format("Creating tables on master~n"),
    create_master_tables(),
    
    timer:sleep(2000),
    
    %% Добавляем копии таблиц на slave узлы
    add_table_copies_to_slaves(),
    
    timer:sleep(2000),
    
    %% Ждём синхронизации
    wait_for_sync(30000),
    
    %% Проверяем статус
    print_replication_status(),
    
    io:format("Cluster setup complete~n"),
    ok.

%% @doc Создание таблиц на master узле
create_master_tables() ->
    Tables = ?TABLES_NAME_LIST,
    
    lists:foreach(fun(Table) ->
        %% Сначала создаем таблицу как ram_copies на master
        Opts = get_table_opts(Table, ram_copies),
        case mnesia:create_table(Table, Opts) of
            {atomic, ok} ->
                io:format("Table ~p created on master as ram_copies~n", [Table]),
                %% Преобразуем в disc_copies
                case mnesia:change_table_copy_type(Table, node(), disc_copies) of
                    {atomic, ok} ->
                        io:format("Table ~p changed to disc_copies on master~n", [Table]);
                    {aborted, Reason} ->
                        io:format("Failed to change table ~p to disc_copies: ~p~n", [Table, Reason])
                end;
            {aborted, {already_exists, _}} ->
                io:format("Table ~p already exists~n", [Table]);
            {aborted, Reason} ->
                io:format("Failed to create table ~p: ~p~n", [Table, Reason])
        end
    end, Tables).

%% @private Добавление копий таблиц на slave узлы
add_table_copies_to_slaves() ->
    Tables = ?TABLES_NAME_LIST,
    
    lists:foreach(fun(Table) ->
        lists:foreach(fun(Node) ->
            io:format("Adding table ~p copy to ~p~n", [Table, Node]),
            case mnesia:add_table_copy(Table, Node, disc_copies) of
                {atomic, ok} -> 
                    io:format("Successfully added ~p to ~p~n", [Table, Node]);
                {aborted, {already_exists, _, _}} ->
                    io:format("Table ~p already exists on ~p~n", [Table, Node]);
                {aborted, Reason} -> 
                    io:format("Failed to add ~p to ~p: ~p~n", [Table, Node, Reason])
            end
        end, ?SLAVE_NODES)
    end, Tables).

%% @private Получить опции для создания таблицы
get_table_opts(Table, StorageType) ->
    case Table of
        users ->
            [{type, set}, {StorageType, [node()]}, {record_name, users},
             {attributes, record_info(fields, users)}, {index, [domain]}];
        registrations ->
            [{type, bag}, {StorageType, [node()]}, {record_name, registrations},
             {attributes, record_info(fields, registrations)}];
        call ->
            [{type, set}, {StorageType, [node()]}, {record_name, call},
             {attributes, record_info(fields, call)}];
        dialplan ->
            [{type, set}, {StorageType, [node()]}, {record_name, dialplan},
             {attributes, record_info(fields, dialplan)}]
    end.

%% @doc Обеспечить репликацию данных на все узлы (для slave)
-spec ensure_replication() -> ok | {error, term()}.
ensure_replication() ->
    io:format("Ensuring Mnesia replication on ~p~n", [node()]),
    
    %% Запускаем Mnesia если не запущена
    case mnesia:system_info(is_running) of
        yes ->
            io:format("Mnesia already running~n");
        no ->
            io:format("Starting Mnesia~n"),
            mnesia:start(),
            timer:sleep(1000)
    end,
    
    %% Подключаемся к мастер узлу
    case net_adm:ping(?MASTER_NODE) of
        pong -> 
            io:format("Connected to master node~n");
        pang ->
            io:format("Cannot connect to master node~n"),
            {error, cannot_connect_to_master}
    end,
    
    %% Ждем появления таблиц от мастера
    wait_for_sync(30000),
    
    %% Проверяем статус
    print_replication_status(),
    
    ok.

%% @doc Ожидание синхронизации таблиц
-spec wait_for_sync(Timeout :: non_neg_integer()) -> ok | {error, term()}.
wait_for_sync(Timeout) ->
    Tables = ?TABLES_NAME_LIST,
    
    %% Ждем пока таблицы появятся
    wait_for_tables_existence(Tables, Timeout),
    
    %% Проверяем существующие таблицы
    ExistingTables = [T || T <- Tables, mnesia:table_info(T, exists)],
    
    case ExistingTables of
        [] ->
            io:format("Warning: No tables found~n"),
            {error, no_tables};
        _ ->
            io:format("Waiting for tables: ~p~n", [ExistingTables]),
            case mnesia:wait_for_tables(ExistingTables, Timeout) of
                ok ->
                    io:format("All tables synchronized~n"),
                    ok;
                {error, Reason} ->
                    io:format("Timeout waiting for tables: ~p~n", [Reason]),
                    {error, Reason}
            end
    end.

%% @private Ожидание появления таблиц
wait_for_tables_existence(_Tables, 0) ->
    ok;
wait_for_tables_existence(Tables, Timeout) ->
    AllExist = lists:all(fun(Table) -> 
        try
            mnesia:table_info(Table, exists),
            true
        catch
            _:_ -> false
        end
    end, Tables),
    
    if AllExist ->
        ok;
    true ->
        timer:sleep(1000),
        wait_for_tables_existence(Tables, Timeout - 1000)
    end.

%% @private Вывод статуса репликации
print_replication_status() ->
    io:format("=== Mnesia Replication Status ===~n"),
    io:format("Current node: ~p~n", [node()]),
    io:format("Schema nodes: ~p~n", [mnesia:system_info(db_nodes)]),
    io:format("Running: ~p~n", [mnesia:system_info(is_running)]),

    Tables = ?TABLES_NAME_LIST,
    lists:foreach(fun(Table) ->
        case mnesia:table_info(Table, exists) of
            true ->
                Nodes = mnesia:table_info(Table, disc_copies),
                io:format("Table ~p: copies on ~p~n", [Table, Nodes]);
            _ ->
                io:format("Table ~p: missing~n", [Table])
        end
    end, Tables),
    io:format("================================~n").
