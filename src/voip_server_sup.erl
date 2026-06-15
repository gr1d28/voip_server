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
        #{  id => voip_server_core,
            start => {voip_server_core, start_link, []},
            restart => permanent,
            shutdown => 2000,
            type => worker,
            modules => [voip_server_core]
        },
        #{  id => voip_server_call_sup,
            start => {voip_server_call_sup, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => supervisor,
            modules => [voip_server_call_sup]
        },
        nksip:get_sup_spec(voip_server_uas, #{
            plugins => [nksip_registrar],
             %% Слушаем на всех интерфейсах
            sip_listen => "sip:0.0.0.0:5060",

            %% Включаем поддержку NAT
            sip_nat => true,
            force_rport => true,
            auto_contact => true,

            outbound_proxy => false,
            register => false,
            role => server_only,
            callback => voip_server_uas
        })
    ],
    io:format("voip_server_sup: SupFlags: ~p~nChildSpec: ~p~n", [SupFlags, ChildSpecs]),
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
