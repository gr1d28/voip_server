%%%-------------------------------------------------------------------
%% @doc voip_server top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(voip_server_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpecs = [
        nksip:get_sup_spec(voip_server_uas, #{
            plugins => [nksip_registrar],
            sip_local_host => "0.0.0.0",
            sip_listen => "sip:all:5060"
        })
    ],
    io:format("voip_server_sup: SupFlags: ~p~nChildSpec: ~p~n", [SupFlags, ChildSpecs]),
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
