rebar3 deps
rebar3 compile
erl -name server_node2@172.40.0.3 \
    -kernel net_ticktime 8 \
    -pa _build/default/lib/*/ebin \
    -config config/sys.config \
    -setcookie "$(cat /root/.erlang.cookie)" \
    -eval "application:ensure_all_started(voip_server)."
