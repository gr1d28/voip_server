%%%-------------------------------------------------------------------
%% @doc Supervisor for dynamic call processes
%% @end
%%%-------------------------------------------------------------------

-module(voip_server_call_sup).

-behaviour(supervisor).

-export([start_link/0, start_call/3]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_call(CallId, ParticipantList, OutgoingInvite) ->
    Args = [CallId, ParticipantList, OutgoingInvite],
    case supervisor:start_child(?MODULE, Args) of
        {ok, Pid} ->
            io:format("Call FSM started successfully: ~p~n", [Pid]),
            {ok, Pid};
        Error ->
            io:format("Failed to start call FSM: ~p~n", [Error]),
            Error
    end.

init([]) ->
    %% Используем simple_one_for_one для динамических процессов
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 60
    },
    ChildSpec = #{
        id => voip_server_call_fsm,
        start => {voip_server_call_fsm, start_link, []},
        restart => transient,
        shutdown => 5000,
        type => worker,
        modules => [voip_server_call_fsm]
    },
    {ok, {SupFlags, [ChildSpec]}}.