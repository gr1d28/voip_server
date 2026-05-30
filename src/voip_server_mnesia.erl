-module(voip_server_mnesia).

-include_lib("voip_server/include/voip_server_nodes.hrl").
-include_lib("voip_server/include/voip_server_db.hrl").

-export([ensure_replication/0, setup_cluster/0]).
-export([wait_for_sync/1]).

%% @doc Обеспечить репликацию данных на все узлы
%% Вызывается при старте на ЛЮБОМ узле (и master, и slave)
-spec ensure_replication() -> ok | {error, term()}.
ensure_replication() ->
    io:format("Ensuring Mnesia replication on ~p~n", [node()]),

    %% Mnesia уже запущена nksip
    case mnesia:system_info(is_running) of
        yes -> ok;
        no -> {error, mnesia_not_running}
    end,

    %% Получаем все узлы кластера
    AllNodes = ?NODE_LIST,
    CurrentNodes = mnesia:system_info(db_nodes),

    io:format("All nodes: ~p, Current schema nodes: ~p~n", [AllNodes, CurrentNodes]),

    %% 1. Расширяем схему на все узлы
    MissingNodes = AllNodes -- CurrentNodes,
    if MissingNodes =/= [] ->
        io:format("Adding missing nodes to schema: ~p~n", [MissingNodes]),
        add_nodes_to_schema(MissingNodes);
    true ->
        io:format("All nodes already in schema~n")
    end,

    %% 2. Убеждаемся, что все таблицы созданы и реплицированы
    ensure_tables_replicated(AllNodes),

    %% 3. Ждем синхронизации
    wait_for_sync(30000),

    %% 4. Проверяем статус
    print_replication_status(),

    ok.

%% @private Добавление узлов в схему
add_nodes_to_schema(Nodes) ->
    %% Сначала расширяем конфигурацию
    case mnesia:change_config(extra_db_nodes, Nodes) of
        {ok, _} -> ok;
        {error, Reason1} ->
            io:format("Warning: change_config error: ~p~n", [Reason1])
    end,

    %% Добавляем каждый узел в схему
    lists:foreach(fun(Node) ->
        case mnesia:add_table_copy(schema, Node, disc_copies) of
            {atomic, ok} ->
                io:format("Schema added to ~p~n", [Node]);
            {aborted, {already_exists, _, _}} ->
                ok;
            {aborted, Reason2} ->
                io:format("Failed to add schema to ~p: ~p~n", [Node, Reason2])
        end
    end, Nodes).

%% @private Обеспечить репликацию таблиц
ensure_tables_replicated(AllNodes) ->
    Tables = ?TABLES_NAME_LIST,

    lists:foreach(fun(Table) ->
        %% Проверяем существует ли таблица
        case mnesia:table_info(Table, exists) of
            true ->
                %% Таблица существует, проверяем копии
                CurrentCopies = get_table_copies(Table),
                MissingNodes = AllNodes -- CurrentCopies,
                if MissingNodes =/= [] ->
                    io:format("Adding table ~p copies to: ~p~n", [Table, MissingNodes]),
                    lists:foreach(fun(Node) ->
                        case mnesia:add_table_copy(Table, Node, disc_copies) of
                            {atomic, ok} ->
                                io:format("Table ~p added to ~p~n", [Table, Node]);
                            {aborted, Reason} ->
                                io:format("Failed to add ~p to ~p: ~p~n", [Table, Node, Reason])
                        end
                    end, MissingNodes);
                true ->
                    io:format("Table ~p already on all nodes~n", [Table])
                end;
            false ->
                %% Таблица не существует, создаем на всех узлах
                io:format("Creating table ~p on all nodes~n", [Table]),
                create_table_on_nodes(Table, AllNodes)
        end
    end, Tables).

%% @private Создание таблицы на узлах
create_table_on_nodes(Table, Nodes) ->
    Opts = case Table of
        users ->
            [{type, set}, {disc_copies, Nodes}, {record_name, users},
             {attributes, record_info(fields, users)}, {index, [domain]}];
        registrations ->
            [{type, bag}, {disc_copies, Nodes}, {record_name, registrations},
             {attributes, record_info(fields, registrations)}];
        call ->
            [{type, set}, {disc_copies, Nodes}, {record_name, call},
             {attributes, record_info(fields, call)}];
        dialplan ->
            [{type, set}, {disc_copies, Nodes}, {record_name, dialplan},
             {attributes, record_info(fields, dialplan)}]
    end,

    case mnesia:create_table(Table, Opts) of
        {atomic, ok} ->
            io:format("Table ~p created~n", [Table]);
        {aborted, {already_exists, _}} ->
            ok;
        {aborted, Reason} ->
            io:format("Failed to create table ~p: ~p~n", [Table, Reason])
    end.

%% @private Получить список узлов с копией таблицы
get_table_copies(Table) ->
    case catch mnesia:table_info(Table, disc_copies) of
        {'EXIT', _} -> [];
        Nodes -> Nodes
    end.

%% @doc Ожидание синхронизации таблиц
-spec wait_for_sync(Timeout :: non_neg_integer()) -> ok | {error, term()}.
wait_for_sync(Timeout) ->
    Tables = ?TABLES_NAME_LIST,
    ExistingTables = [T || T <- Tables, mnesia:table_info(T, exists)],

    case ExistingTables of
        [] ->
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

%% @doc Вывод статуса репликации
-spec print_replication_status() -> ok.
print_replication_status() ->
    io:format("=== Mnesia Replication Status ===~n"),
    io:format("Current node: ~p~n", [node()]),
    io:format("Schema nodes: ~p~n", [mnesia:system_info(db_nodes)]),
    io:format("Running: ~p~n", [mnesia:system_info(is_running)]),

    Tables = ?TABLES_NAME_LIST,
    lists:foreach(fun(Table) ->
        case catch mnesia:table_info(Table, disc_copies) of
            {'EXIT', _} ->
                io:format("Table ~p: missing~n", [Table]);
            Nodes ->
                io:format("Table ~p: copies on ~p~n", [Table, Nodes])
        end
    end, Tables),
    io:format("================================~n").

%% @doc Установка кластера с нуля
-spec setup_cluster() -> ok.
setup_cluster() ->
    io:format("Setting up Mnesia cluster~n"),

    %% Останавливаем Mnesia если запущена
    case mnesia:system_info(is_running) of
        yes -> mnesia:stop();
        no -> ok
    end,

    %% Удаляем старую схему на всех узлах
    lists:foreach(fun(Node) ->
        rpc:call(Node, mnesia, delete_schema, [[Node]]),
        rpc:call(Node, mnesia, stop, [])
    end, ?NODE_LIST),

    %% Создаем схему на мастере
    rpc:call(?MASTER_NODE, mnesia, create_schema, [[?MASTER_NODE]]),

    %% Запускаем Mnesia на всех узлах
    lists:foreach(fun(Node) ->
        rpc:call(Node, mnesia, start, [])
    end, ?NODE_LIST),

    %% Добавляем slave узлы в схему (выполняем на мастере)
    rpc:call(?MASTER_NODE, ?MODULE, add_nodes_to_schema, [?SLAVE_NODES]),

    %% Создаем таблицы на мастере
    rpc:call(?MASTER_NODE, ?MODULE, ensure_tables_replicated, [?NODE_LIST]),

    io:format("Cluster setup complete~n"),
    ok.
