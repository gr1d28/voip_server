%%%-------------------------------------------------------------------
%%% @doc Модуль для обработки SIP событий и создания сессий звонков
%%% @end
%%%-------------------------------------------------------------------
%% TODO предусмотреть восстановление процессов call_fsm при падении call_fsm_sup
%% TODO переделать состояние, все fsm_pid брать из mnesia
-module(voip_server_core).

-behaviour(gen_server).

-include_lib("voip_server/include/voip_server_db.hrl").
-include_lib("voip_server/include/voip_server_call_fsm.hrl").

-export([start_link/0, init/1, terminate/2, handle_cast/2, handle_call/3, handle_info/2, code_change/3]).
-export([create_call/1, send_bye/1, send_cancel/1]).
-export([add_call_id_b/2, delete_call_id/1, change_call_id/2]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec create_call({nksip:call_id(), participant_list(), outgoing_invite()}) -> ok.
create_call({CallId, ParticipantList, OutgoingInvite}) ->
    io:format("local call create~n"),
    gen_server:cast(?MODULE, {add_call, CallId, ParticipantList, OutgoingInvite}).

-spec send_bye({nksip:call_id(), binary(), binary(), binary(), binary(), nksip:handle()}) -> ok.
send_bye({CallId, FromUser, FromDomain, ToUser, ToDomain, ReqId}) ->
    gen_server:cast(?MODULE, {bye, CallId, FromUser, FromDomain, ToUser, ToDomain, ReqId}).

-spec send_cancel(nksip:call_id()) -> ok.
send_cancel(CallId) ->
    gen_server:cast(?MODULE, {cancel, CallId}).

%% private for call_fsm
%% Добавление второго плеча звонка (call_id_b) в state
-spec add_call_id_b(nksip:call_id(), pid()) -> ok.
add_call_id_b(CallIdB, FsmPid) ->
    gen_server:cast(?MODULE, {add_call_id_b, CallIdB, FsmPid}).

%% Удаление call_id из состояния core
-spec delete_call_id(nksip:call_id()) -> ok.
delete_call_id(CallId) ->
    gen_server:cast(?MODULE, {delete_call_id, CallId}).

%% Изменение идентификатора pid процесса обработчика вызова fsm (при восстановлении fsm процесса)
-spec change_call_id(nksip:call_id(), pid()) -> ok.
change_call_id(CallId, FsmPid) ->
    gen_server:cast(?MODULE, {change_call_id, CallId, FsmPid}).

-spec init([]) -> {ok, [{nksip:call_id(), pid()}] | []}.
init([]) ->
    CallIdList1 = voip_server_db:get_all_map_CallId_FsmPid(),
    CallIdList2 = lists:foldl(fun ({CallIdA, CallIdB, FsmPid}, Acc) -> case is_process_alive(FsmPid) of
        true -> [{CallIdB, FsmPid}, {CallIdA, FsmPid} | Acc];
        false -> Acc
    end end, [], CallIdList1),
    io:format("core: module is initialized. Number of active calls - ~p~n", [length(CallIdList2) div 2]),
    {ok, CallIdList2}.

terminate(Reason, _St) ->
    io:format("core: terminate with reason: ~p~n", [Reason]),
    ok.

handle_cast({add_call, CallId, ParticipantList, OutgoingInvite}, CallIdList) ->
    io:format("core: receive add_call cast~n"),
    case lists:keyfind(CallId, 1, CallIdList) of
        false ->
            io:format("core: start new call_fsm process with call_id - ~p~n", [CallId]),
            case voip_server_call_sup:start_call(CallId, ParticipantList, OutgoingInvite) of
                {ok, FsmPid} ->
                    io:format("core: call_fsm with call_id ~p has been started~n", [CallId]),
                    {noreply, [{CallId, FsmPid} | CallIdList]};
                {error, Reason} ->
                    io:format("core: error in starting call_fsm with call_id ~p: ~p~n", [CallId, Reason]),
                    {noreply, CallIdList}
            end;
        {_, FsmPid} ->
            io:format("core: call with call_id ~p has already started~n", [CallId]),
            voip_server_call_fsm:re_invite(FsmPid, {ParticipantList, OutgoingInvite}),
            {noreply, CallIdList}
    end;
handle_cast({bye, CallId, FromUser, FromDomain, ToUser, ToDomain, ReqId}, CallIdList) ->
    io:format("core: receive bye cast~n"),
    case lists:keyfind(CallId, 1, CallIdList) of
        false ->
            io:format("core: call with call_id ~p not exist~n", [CallId]),
            {noreply, CallIdList};
        {_, FsmPid} ->
            io:format("core: sending bye and stop call with call_id ~p~n", [CallId]),
            voip_server_call_fsm:bye(FsmPid, {FromUser, FromDomain, ToUser, ToDomain, ReqId}),
            {noreply, CallIdList}
    end;
handle_cast({cancel, CallId}, CallIdList) ->
    io:format("core: receive cancel cast~n"),
    case lists:keyfind(CallId, 1, CallIdList) of
        false ->
            io:format("core: call with call_id ~p not exist~n", [CallId]),
            {noreply, CallIdList};
        {_, FsmPid} ->
            io:format("core: sending cancel and stop call with call_id ~p~n", [CallId]),
            voip_server_call_fsm:cancel(FsmPid),
            {noreply, CallIdList}
    end;
handle_cast({add_call_id_b, CallIdB, FsmPid}, CallIdList) ->
    io:format("core: receive add_call_id_b cast~n"),
    {noreply, [{CallIdB, FsmPid} | CallIdList]};
handle_cast({delete_call_id, CallId}, CallIdList) ->
    io:format("core: receive delete_call_id cast~n"),
    NewCallIdList = lists:keydelete(CallId, 1, CallIdList),
    {noreply, NewCallIdList};
handle_cast({change_call_id, CallId, FsmPid}, CallIdList) ->
    io:format("core: receive change_call_id cast~n"),
    lists:foldl(fun
        ({CallId1, _}, Acc) when CallId1 =:= CallId -> [{CallId, FsmPid} | Acc];
        (_, Acc) -> Acc
    end, [], CallIdList);
handle_cast(Msg, St) ->
    io:format("core: unknown cast msg - ~p~n", [Msg]),
    [noreply, St].

handle_call(Msg, From, St) ->
    io:format("core: unknown call Msg - ~p, From - ~p~n", [Msg, From]),
    {reply, {error, {unknown_call, Msg}}, St}.

handle_info(Msg, St) ->
    io:format("core: unknown info Msg - ~p~n", [Msg]),
    {noreply, St}.

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.
