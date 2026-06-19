-module(http_server).
-behaviour(cowboy_handler).

-export([start_http_server/0]).
-export([init/2]).

start_http_server() ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/health", http_server, []}
        ]}
    ]),

    {ok, _} = cowboy:start_clear(
        http_listener,
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ).

init(Req0, State) ->
    Method = cowboy_req:method(Req0),
    handle_request(Method, Req0, State).

handle_request(<<"GET">>, Req0, State) ->
    Response = jsx:encode(#{<<"status">> => <<"healthy">>, <<"node">> => erlang:atom_to_binary(node(), utf8), <<"timestamp">> => erlang:system_time(millisecond)}),
    Req = cowboy_req:reply(200, #{
        <<"content-type">> => <<"application/json">>
    }, Response, Req0),
    {ok, Req, State}.
