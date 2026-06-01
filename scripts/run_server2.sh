rebar3 compile
erl -name server_node2@172.40.0.3 \
    -kernel net_ticktime 8 \
    -pa _build/default/lib/*/ebin \
    -config config/sys.config \
    -setcookie "$(cat /root/.erlang.cookie)" \
    -eval "
        voip_server_db:start_slave(),
        {ok, _} = application:ensure_all_started(voip_server),
        io:format('Slave node ready, waiting for failover...~n').
    "
