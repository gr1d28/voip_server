rebar3 compile
erl -name server_node2@172.40.0.3 \
    -pa _build/default/lib/*/ebin \
    -config config/sys.config \
    -setcookie "$(cat /root/.erlang.cookie)" \
    -eval "
        %% Запускаем Mnesia и настраиваем репликацию
        ok = voip_server_mnesia:ensure_replication(),

        %% Регистрируем узел в кластере
        net_adm:ping('server_node1@172.40.0.2'),

        %% Не запускаем voip_server application (ждем failover)
        io:format('Slave node ready, waiting for failover...~n'),

        %% Мониторим master узел
        erlang:monitor_node('server_node1@172.40.0.2', true),
        receive
            {nodedown, 'server_node1@172.40.0.2'} ->
                io:format('Master node down, starting application~n'),
                application:start(voip_server)
        end.
    "
