FROM erlang:21

WORKDIR /app

COPY rebar.config ./

RUN rebar3 deps

COPY . .

RUN mkdir -p /app/data
RUN rebar3 compile

CMD ["rebar3", "shell", "--name", "server_node@172.40.0.2", "--apps", "voip_server"]
