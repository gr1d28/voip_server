rebar3 compile
erl -name server_node1@172.40.0.2 \
    -kernel net_ticktime 8 \
    -pa _build/default/lib/*/ebin \
    -config config/sys.config \
    -setcookie "$(cat /root/.erlang.cookie)" \
    -eval "
        %% Сначала настраиваем кластер Mnesia
        ok = voip_server_db:start_master(),

        %% Запускаем приложение
        {ok, _} = application:ensure_all_started(voip_server),

        io:format('Master node running~n').
    "
