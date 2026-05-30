rebar3 compile
erl -name server_node1@172.40.0.2 \
    -kernel net_ticktime 8 \
    -pa _build/default/lib/*/ebin \
    -config config/sys.config \
    -setcookie "$(cat /root/.erlang.cookie)" \
    -eval "
        %% Запускаем Mnesia и репликацию
        ok = voip_server_mnesia:setup_cluster(),

        %% Запускаем приложение
        application:start(voip_server),

        io:format('Master node running~n')
    "
