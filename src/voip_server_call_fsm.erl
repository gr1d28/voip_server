%%%-------------------------------------------------------------------
%%% @doc Модуль управления состояниями вызовов B2BUA
%%% @end
%%%-------------------------------------------------------------------

-module(voip_server_call_fsm).

-behaviour(gen_statem).

-include_lib("nklib/include/nklib.hrl").
-include_lib("voip_server/include/voip_server_db.hrl").
-include_lib("voip_server/include/voip_server_call_fsm.hrl").

-export([start_link/3, stop/1]).
-export([callback_mode/0, init/1, terminate/3, code_change/4]).
-export([bye/1, cancel/1]).
-export([calling/3, active/3]).

-spec start_link(nksip:call_id(), participant_list(), outgoing_invite()) ->
    {ok, pid()} | {error, term()}.
start_link(CallId, ParticipantList, OutgoingInvite) ->
    gen_statem:start_link(?MODULE, [CallId, ParticipantList, OutgoingInvite], []).

cancel({CallId, FromUser, FromDomain, ToUser, ToDomain}) ->
    [Call] = voip_server_db:get_call(CallId),
    FromAOR = {sip, FromUser, FromDomain},
    ToAOR = {sip, ToUser, ToDomain},
    io:format("call_fsm: send message~n"),
    Call#call.fsm_pid ! cancel.

%% TODO сделать получение в active из базы а не из локального состояния
bye({CallId, FromUser, FromDomain, ToUser, ToDomain, ReqId}) ->
    [Call] = voip_server_db:get_call(CallId),
    FromAOR = {sip, FromUser, FromDomain},
    ToAOR = {sip, ToUser, ToDomain},
    gen_statem:cast(Call#call.fsm_pid, {bye, FromAOR, ToAOR, ReqId}).

stop(Pid) ->
    gen_statem:stop(Pid).

callback_mode() -> state_functions.

code_change(_OldVsn, State, Data, _Extra) ->
    io:format("call_fsm: code change~n"),
    {ok, State, Data}.

terminate(_Reason, calling, {Call, _, _}) ->
    io:format("call_fsm: terminate calling~n"),
    voip_server_db:delete_call(Call#call.call_id),
    io:format("call_fsm: call ~p deleted~n", [Call#call.call_id]),
    ok;
terminate(_Reason, active, CallId) ->
    io:format("call_fsm: terminate active~n"),
    voip_server_db:delete_call(CallId),
    io:format("call_fsm: call ~p deleted~n", [CallId]),
    ok.

init([CallId, ParticipantList, OutgoingInvite]) ->
    io:format("call_fsm: call_id = ~p~n", [CallId]),
    ParticipantRecordList = make_participant_list(ParticipantList),
    CallRecord = #call{
        call_id = CallId,
        fsm_pid = self(),
        participants = ParticipantRecordList,
        state = initializing,
        start_time = erlang:now()
    },
    voip_server_db:add_call(CallRecord),    %% TODO добавить проверку, что звонок ещё не создан
    [Initiator, InvitedParticipant] = ParticipantRecordList,      %% Отдельно вызывающий и вызываемые абоненты
    io:format("call_fsm: out init~n"),
    {ok, calling, {CallRecord, Initiator, InvitedParticipant}, {next_event, internal, {outgoing_invite, OutgoingInvite}}}.

calling(internal, {outgoing_invite, #outgoing_invite{target_uri = TargetUri, serv_id = AppId, from = OriginalFrom, to = OriginalTo, domain = ServerDomain, port = ServerPort}},
    {Call, Initiator, InvitedParticipant}) ->
    io:format("call_fsm: enter calling outgoing_invite~n"),
    TargetUri2 = TargetUri#uri{domain = ServerDomain, port = ServerPort},

    % Self = self(),
    % FsmCallback = fun(Result) -> 
    %     Self ! {nksip_uac_reply, self(), Result} 
    % end,

    Opts = [
        {callback, nksip_uac_dialplan_callbacks},
        {cb_obj, self()},
        {call_id, Call#call.call_id},
        {from, OriginalFrom},
        {to, OriginalTo},
        {contact, TargetUri2},
        {body, Initiator#participant.sdp},
        {get_meta, [contacts, body]}
    ],

    io:format("call_fsm: Request Handle Initiator = ~p, Role = ~p~n", [Initiator#participant.request_handle, Initiator#participant.role]),
    io:format("call_fsm: TargetURI = ~p TargetURI2 = ~p~n", [TargetUri, TargetUri2]),

    ReqId = nksip_uac:invite(AppId, TargetUri, Opts),
    io:format("call_fsm: ReqId = ~p~n", [ReqId]),
    {keep_state, {Call, Initiator, InvitedParticipant}};
calling(info, {nksip_uac_reply, _FromPid, {resp, 180, Req}}, {Call, Initiator, InvitedParticipant}) ->
    io:format("call_fsm: calling 180 ringing~n"),
    nksip_request:reply(ringing, Initiator#participant.request_handle),

    {ok, ReqId} = nksip_request:get_handle(Req),
    {ok, OutDialogId} = nksip_dialog:get_handle(Req),
    io:format("call_fsm: ReqId = ~p~nOutDialogId = ~p~n", [ReqId, OutDialogId]),

    NewInvitedParticipant = InvitedParticipant#participant{status = ringing, request_handle = ReqId, dialog_handle = OutDialogId},
    NewCall = Call#call{participants = [Initiator, NewInvitedParticipant], state = ringing},
    {keep_state, {NewCall, Initiator, NewInvitedParticipant}};
calling(info, Msg, {_Call, _Initiator, _InvitedParticipant}) ->
    io:format("call_fsm: info msg = ~p~n", [Msg]),
    {stop, normal};

    % PidInviter = spawn_link(?MODULE, send_invite, [{form, self()}, AppId, TargetUri, Opts]),

    % receive
    %     {ok, Code, OutDialogHandle} when Code >= 200 andalso Code < 300 ->
    %         {dialog, OutDialogId} = lists:keyfind(dialog, 1, OutDialogHandle),

    %         RemoteBody = lists:keyfind(body, 1, OutDialogHandle),

    %         {contacts, [Contact1 | _OtherContacts]} = lists:keyfind(contacts, 1, OutDialogHandle),
    %         Contact2 = Contact1#uri{domain = ServerDomain, port = ServerPort},

    %         {body, SDPStruct} = RemoteBody,

    %         Opts2 = [
    %             {body, SDPStruct},
    %             {contact, Contact2}
    %         ],
    %         case nksip_request:reply({ok, Opts2}, Initiator#participant.request_handle) of
    %             ok ->
    %                 nksip_uac:ack(OutDialogId, []);
    %             {error, Reason} ->
    %                 io:format("call_fsm: error in nksip_request:reply ~p~n", [Reason])
    %         end,

    %         #uri{user = OutUser, domain = OutDomain} = TargetUri2,

    %         NewInvitedParticipant = InvitedParticipant#participant{status = active, dialog_handle = OutDialogId, sdp = SDPStruct},
    %         NewInitiator = Initiator#participant{status = active, request_handle = undefined},

    %         NewCall = Call#call{participants = [NewInitiator, NewInvitedParticipant], state = active},
    %         {next_state, active, {NewCall}};
    %     cancel ->
    %         case nksip_uac:cancel()
    %     {error, Reason} ->
    %         io:format("call_fsm: Failed to create outgoing call: ~p~n", [Reason]),
    %         {stop, normal};
    %     Answer ->
    %         io:format("call_fsm: Unexpected answer: ~p~n", [Answer]),
    %         {stop, normal}
    % after
    %     30000 ->
    %         io:format("call_fsm: timeout for invite calling~n"),
    %         {stop, normal}
    % end;
calling(EventType, EventContent, Data) ->
    io:format("call_fsm: Unexpected event ~p: ~p~n", [EventType, EventContent]),
    {keep_state, Data}.

active(cast, {bye, FromAOR, ToAOR, ReqId}, {Call}) ->
    io:format("call_fsm: active cast send BYE message from ~p~n", [FromAOR]),

    % FromParticipant = lists:keyfind(FromAOR, #participant.id, Call#call.participants),
    ToParticipant = lists:keyfind(ToAOR, #participant.id, Call#call.participants),

    case nksip_uac:bye(ToParticipant#participant.dialog_handle, []) of
        {ok, Code, _} when Code >= 200 andalso Code < 300 ->
            io:format("call_fsm: 200 sending bye to ~p~n", [ToAOR]),
            case nksip_request:reply(Code, ReqId) of
                ok ->
                    io:format("call_fsm: normal end call~n"),
                    {stop, normal, Call#call.call_id};
                {error, Reason} ->
                    io:format("call_fsm: error in request to ~p: ~p~n", [FromAOR, Reason]),
                    {stop, normal};
                Answer ->
                    io:format("call_fsm: unexpected answer from nksip_request:reply/2 ~p: ~p", [FromAOR, Answer])
            end;
        {error, Reason} ->
            io:format("call_fsm: error in send bye to ~p: ~p~n", [ToAOR, Reason]),
            {stop, normal};
        Answer ->
            io:format("call_fsm: unexpected answer from nksip_uac:bye/2 ~p: ~p", [ToAOR, Answer]),
            {stop, normal}
    end;
active(EventType, EventContent, Data) ->
    io:format("call_fsm: Unexpected event ~p: ~p~n", [EventType, EventContent]),
    {keep_state, Data}.

% @private
-spec make_participant_list(participant_list()) -> [#participant{}].
make_participant_list(ParticipantList) ->
    lists:reverse(make_participant_list(ParticipantList, [])).

make_participant_list([], Acc) -> Acc;
make_participant_list([H | T], Acc) ->
    User = maps:get(?USER_NAME, H),
    Domain = maps:get(?DOMAIN_NAME, H),
    Role = maps:get(?ROLE, H),
    Status = case Role of
        caller -> inviting;
        _ -> hold
    end,
    ReqId = maps:get(?REQUEST_HANDLE, H, undefined),
    DialogId = maps:get(?DIALOG_HANDLE, H, undefined),
    SDP = maps:get(?SDP, H, undefined),
    Participant = #participant{
        id = {sip, User, Domain},
        role = Role,
        status = Status,
        request_handle = ReqId,
        dialog_handle = DialogId,
        sdp = SDP
    },
    make_participant_list(T, [Participant | Acc]).

% send_invite({from, Pid}, AppId, TargetUri, Opts) ->
%    Pid ! nksip_uac:invite(AppId, TargetUri, Opts).
