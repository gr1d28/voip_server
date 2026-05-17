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

cancel(CallId) ->
    io:format("Send cast cancel~n"),
    case voip_server_db:get_call(CallId) of
        [] ->
            io:format("The call has already stopped~n");
        [Call] ->
            gen_statem:cast(Call#call.fsm_pid, cancel)
    end.

%% TODO сделать получение в active из базы, а не из локального состояния
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

terminate(Reason, calling, {Call, _OutgoingInvite}) ->
    io:format("call_fsm: terminate calling with reason: ~p~n", [Reason]),
    voip_server_db:delete_call(Call#call.call_id),
    io:format("call_fsm: call ~p deleted~n", [Call#call.call_id]),
    ok;
terminate(_Reason, active, Call) ->
    io:format("call_fsm: terminate active~n"),
    CallId = Call#call.call_id,
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
    io:format("call_fsm: out init~n"),
    {ok, calling, {CallRecord, OutgoingInvite}, {next_event, internal, outgoing_invite}}.

%% Посылка вызова второму абоненту в асинхронном режиме обработки
calling(internal, outgoing_invite, {#call{participants = [Initiator, InvitedParticipant]} = Call,
    #outgoing_invite{target_uri = TargetUri, serv_id = AppId, from = OriginalFrom, to = OriginalTo, domain = ServerDomain, port = ServerPort} = OutgoingInvite}) ->
    io:format("call_fsm: enter calling outgoing_invite~n"),
    {sip, InitiatorName, _} = Initiator#participant.id,
    Contact = TargetUri#uri{user = InitiatorName, domain = ServerDomain, port = ServerPort},

    Self = self(),
    FsmCallback = fun(Result) ->
        Self ! {nksip_uac_reply, self(), Result}
    end,

    Opts = [
        async,
        {callback, FsmCallback},
        {call_id, Call#call.call_id},
        {to, OriginalTo},
        {from, OriginalFrom},
        {contact, Contact},
        {body, Initiator#participant.sdp},
        {get_meta, [contacts, body]}
    ],

    io:format("call_fsm: Request Handle Initiator = ~p, Role = ~p~n", [Initiator#participant.request_handle, Initiator#participant.role]),
    io:format("call_fsm: TargetURI = ~p Contact = ~p~n", [TargetUri, Contact]),

    {async, ReqId} = nksip_uac:invite(AppId, TargetUri, Opts),
    io:format("call_fsm: ReqId = ~p~n", [ReqId]),
    NewInvitedParticipant = InvitedParticipant#participant{status = ringing, request_handle = ReqId},
    NewCall = Call#call{participants = [Initiator, NewInvitedParticipant]},
    {keep_state, {NewCall, OutgoingInvite}};
%% Пришел 180 Ringing
calling(info, {nksip_uac_reply, _FromPid, {resp, 180, Req, _C}}, {#call{participants = [Initiator, InvitedParticipant]} = Call, OutgoingInvite}) ->
    io:format("call_fsm: calling 180 ringing~n"),
    case nksip_request:reply(ringing, Initiator#participant.request_handle) of
        ok -> ok;
        {error, Reason} -> io:format("call_fsm: error in reply initiator: ~p~n", [Reason])
    end,
    {ok, OutDialogId} = nksip_dialog:get_handle(Req),
    io:format("call_fsm: OutDialogId = ~p~n", [OutDialogId]),

    NewInvitedParticipant = InvitedParticipant#participant{status = ringing, dialog_handle = OutDialogId},
    NewCall = Call#call{participants = [Initiator, NewInvitedParticipant], state = ringing},
    {keep_state, {NewCall, OutgoingInvite}, {state_timeout, ?INVITE_TIMEOUT, calling_invite_timeout}};
%% Вызываемый абонент ответил на звонок
%% Соединяем абонентов
calling(info, {nksip_uac_reply, _FromPid, {resp, 200, Req, _C}}, {#call{participants = [Initiator, InvitedParticipant]} = Call, OutgoingInvite}) ->
    io:format("call_fsm: 200 OK~n"),
    Body = nksip_sipmsg:get_meta(body, Req),
    [Contact | _Other] = nksip_sipmsg:get_meta(contacts, Req),
    io:format("call_fsm: body = ~p~n", [Body]),

    Contact2 = Contact#uri{domain = OutgoingInvite#outgoing_invite.domain, port = OutgoingInvite#outgoing_invite.port},
    io:format("call_fsm: Contact2 = ~p~n", [Contact2]),

    OriginalFrom = OutgoingInvite#outgoing_invite.from,
    OriginalTo = OutgoingInvite#outgoing_invite.to,
    Opts = [
        {to, OriginalTo},
        {from, OriginalFrom},
        {body, Body},
        {contact, Contact2}
    ],
    io:format("call_fsm: OriginalFrom = ~p OriginalTo = ~p~n", [OriginalFrom, OriginalTo]),

    case nksip_request:reply({ok, Opts}, Initiator#participant.request_handle) of
        ok ->
            nksip_uac:ack(InvitedParticipant#participant.dialog_handle, []),        %% TODO обработать
            io:format("call_fsm: successful connection of subscribers ~p and ~p~n", [Initiator#participant.id, InvitedParticipant#participant.id]),
            NewInvitedParticipant = InvitedParticipant#participant{status = active, request_handle = undefined, sdp = Body},
            NewInitiator = Initiator#participant{status = active, request_handle = undefined},

            NewCall = Call#call{participants = [NewInitiator, NewInvitedParticipant], state = active},
            {next_state, active, NewCall};
        {error, Reason} ->
            io:format("call_fsm: error in send reply for initiator: ~p~n", [Reason]),
            {stop, normal}
    end;
%% Вызываемый абонент занят - завершаем звонок
%% Отправляем busy вызывающему, вызываемому nksip сам отправит ACK
calling(info, {nksip_uac_reply, _FromPid, {resp, 486, _Req, _C}}, {#call{participants = [Initiator, _InvitedParticipant]} = _Call, _OutgoingInvite}) ->
    io:format("call_fsm: 486 busy here~n"),
    case nksip_request:reply(busy, Initiator#participant.request_handle) of
        ok -> ok;
        {error, Reason} -> io:format("call_fsm: error in reply initiator: ~p~n", [Reason])
    end,
    {stop, normal};
%% Вызываемый абонент не ответил на звонок
%% Отправляем temporarily_unavailable вызывающему, вызываемому nksip сам отправит ACK
calling(info, {nksip_uac_reply, _FromPid, {resp, 480, _Req, _C}}, {#call{participants = [Initiator, _InvitedParticipant]} = _Call, _OutgoingInvite}) ->
    io:format("call_fsm: 480 user not responding~n"),
    case nksip_request:reply(temporarily_unavailable, Initiator#participant.request_handle) of
        ok -> ok;
        {error, Reason} -> io:format("call_fsm: error in reply initiator: ~p~n", [Reason])
    end,
    {stop, normal};
calling(info, Msg, {_Call, _OutgoingInvite}) ->
    io:format("call_fsm: info msg = ~p~n", [Msg]),
    {stop, normal};
%% Шлём CANCEL в диалог вызываемого абонента, если пришёл от вызывающего, и завершаем звонок
%% Вызывающему 200 OK отправит сам nksip
calling(cast, cancel, {#call{participants = [_Initiator, InvitedParticipant]} = _Call, _OutgoingInvite}) ->
    io:format("call_fsm: cast cancel in calling~n"),
    Result = nksip_uac:cancel(InvitedParticipant#participant.request_handle, []),
    io:format("call_fsm: send cancel to callee result = ~p~n", [Result]),
    {stop, normal};
%% Вызываемый абонент не отвечает спустя INVITE_TIMEOUT мс
%% Завершаем звонок по 408 Request Timeout
calling(state_timeout, calling_invite_timeout, {#call{participants = [Initiator, InvitedParticipant]} = _Call, _OutgoingInvite}) ->
    nksip_uac:cancel(InvitedParticipant#participant.request_handle, []),
    case nksip_request:reply(timeout, Initiator#participant.request_handle) of
        ok -> ok;
        {error, Reason} -> io:format("call_fsm: error in reply initiator: ~p~n", [Reason])
    end,
    io:format("call_fsm: the call ended by timeout~n"),
    {stop, normal};
calling(EventType, EventContent, Data) ->
    io:format("call_fsm: Unexpected event ~p: ~p~n", [EventType, EventContent]),
    {keep_state, Data}.

%% Поймали сигнал BYE от одного из абонентов на стадии активного звонка
%% Разъединяем абонентов
active(cast, {bye, FromAOR, ToAOR, ReqId}, Call) ->
    io:format("call_fsm: active cast send BYE message from ~p~n", [FromAOR]),

    ToParticipant = lists:keyfind(ToAOR, #participant.id, Call#call.participants),

    case nksip_uac:bye(ToParticipant#participant.dialog_handle, []) of
        {ok, Code, _} when Code >= 200 andalso Code < 300 ->
            io:format("call_fsm: 200 sending bye to ~p~n", [ToAOR]),
            case nksip_request:reply(Code, ReqId) of
                ok ->
                    io:format("call_fsm: normal end call~n"),
                    {stop, normal};
                {error, Reason} ->
                    io:format("call_fsm: error in request to ~p: ~p~n", [FromAOR, Reason]),
                    {stop, normal};
                Answer ->
                    io:format("call_fsm: unexpected answer from nksip_request:reply/2 ~p: ~p", [FromAOR, Answer]),
                    {stop, normal}
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
