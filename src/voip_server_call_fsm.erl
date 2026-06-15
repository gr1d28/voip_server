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
-export([bye/2, cancel/1, re_invite/2]).
-export([calling/3, active/3]).

-spec start_link(nksip:call_id(), participant_list(), outgoing_invite()) ->
    {ok, pid()} | {error, term()}.
start_link(CallId, ParticipantList, OutgoingInvite) ->
    gen_statem:start_link(?MODULE, [CallId, ParticipantList, OutgoingInvite], []).

-spec cancel(pid()) -> ok.
cancel(FsmPid) ->
    gen_statem:cast(FsmPid, cancel).

-spec bye(pid(), {binary(), binary(), binary(), binary(), nksip:handle()}) -> ok.
bye(FsmPid, {FromUser, FromDomain, ToUser, ToDomain, ReqId}) ->
    FromAOR = {sip, FromUser, FromDomain},
    ToAOR = {sip, ToUser, ToDomain},
    gen_statem:cast(FsmPid, {bye, FromAOR, ToAOR, ReqId}).

re_invite(FsmPid, {ParticipantList, OutgoingInvite}) ->
    ParticipantRecordList = make_participant_list(ParticipantList),
    gen_statem:cast(FsmPid, {re_invite, ParticipantRecordList, OutgoingInvite}).

stop(Pid) ->
    gen_statem:stop(Pid).

callback_mode() -> state_functions.

code_change(_OldVsn, State, Data, _Extra) ->
    io:format("call_fsm: code change~n"),
    {ok, State, Data}.

%% TODO не удалять звонки, а переводить их в состояние terminated
terminate(Reason, calling, {Call, _OutgoingInvite}) ->
    io:format("call_fsm: terminate calling with reason: ~p~n", [Reason]),
    voip_server_core:delete_call_id(Call#call.call_id_a),
    voip_server_core:delete_call_id(Call#call.call_id_b),
    voip_server_db:delete_call(Call#call.call_id_a),
    io:format("call_fsm: call ~p deleted~n", [Call#call.call_id_a]),
    ok;
terminate(_Reason, active, {Call, _OutgoingInvite}) ->
    io:format("call_fsm: terminate active~n"),
    CallId = Call#call.call_id_a,
    voip_server_core:delete_call_id(Call#call.call_id_a),
    voip_server_core:delete_call_id(Call#call.call_id_b),
    voip_server_db:delete_call(CallId),
    io:format("call_fsm: call ~p deleted~n", [CallId]),
    ok;
terminate(_Reason, active, Call) ->
    io:format("call_fsm: terminate active~n"),
    CallId = Call#call.call_id_a,
    voip_server_core:delete_call_id(Call#call.call_id_a),
    voip_server_core:delete_call_id(Call#call.call_id_b),
    voip_server_db:delete_call(CallId),
    io:format("call_fsm: call ~p deleted~n", [CallId]),
    ok.

%% TODO проверять, есть ли в базе CallId - если да, то переходить в соответствующее состояние.
%% Для работы этой логики ещё необходимо сделать restart не temporary, а transient
init([CallIdA, ParticipantList, OutgoingInvite]) ->
    io:format("call_fsm: call_id_a = ~p~n", [CallIdA]),
    case voip_server_db:get_call(CallIdA) of
        [] ->
            io:format("call_fsm: init new call~n"),
            ParticipantRecordList = make_participant_list(ParticipantList),
            CallRecord = #call{
                call_id_a = CallIdA,
                call_id_b = undefined,
                fsm_pid = self(),
                participants = ParticipantRecordList,
                state = initializing,
                start_time = erlang:timestamp(),
                from_header = OutgoingInvite#outgoing_invite.from,
                to_header = OutgoingInvite#outgoing_invite.to
            },
            voip_server_db:add_call(CallRecord),
            {ok, calling, {CallRecord, OutgoingInvite}, {next_event, internal, outgoing_invite}};
        [ExistCall] ->
            io:format("call_fsm: init exist call~n"),
            ExistCallState = ExistCall#call.state,
            case ExistCallState of
                initializing ->
                    io:format("call_fsm: initializing state call~n"),
                    NewCall = ExistCall#call{fsm_pid = self()},
                    voip_server_core:change_call_id(CallIdA, self()),
                    voip_server_db:add_call(NewCall),
                    {ok, calling, {NewCall, OutgoingInvite}, {next_event, internal, outgoing_invite}};
                _ ->
                    io:format("call_fsm: ~p state call~n", [ExistCallState]),
                    FsmState = case lists:member(ExistCallState, [trying, ringing]) of
                        true -> calling;
                        false -> active
                    end,
                    NewCall = ExistCall#call{fsm_pid = self()},
                    CallIdB = ExistCall#call.call_id_b,
                    voip_server_core:change_call_id(CallIdA, self()),
                    voip_server_core:change_call_id(CallIdB, self()),
                    voip_server_db:add_call(NewCall),
                    {ok, FsmState, {NewCall, OutgoingInvite}}
            end
    end.

%% Посылка вызова второму абоненту в асинхронном режиме обработки
calling(internal, outgoing_invite, {#call{participants = [Initiator, InvitedParticipant]} = Call,
    #outgoing_invite{target_uri = TargetUri, serv_id = AppId, domain = ServerDomain, port = ServerPort} = OutgoingInvite}) ->
    io:format("call_fsm: enter calling outgoing_invite~n"),
    {sip, InitiatorName, _} = Initiator#participant.id,
    Contact = TargetUri#uri{user = InitiatorName, domain = ServerDomain, port = ServerPort},

    CallIdA = Call#call.call_id_a,
    FsmCallback = fun(Result) ->
        case voip_server_db:get_call(CallIdA) of
            [] ->
                io:format("call_fsm: error in fsm_callback_fun/1: not found call ~p~n", [CallIdA]);
            [ExistCall] ->
                ExistCall#call.fsm_pid ! {nksip_uac_reply, self(), Result}
        end
    end,

    CallIdB = iolist_to_binary([integer_to_list(erlang:system_time(millisecond)), "-", nklib_util:luid()]),

    Opts = [
        async,
        {callback, FsmCallback},
        {call_id, CallIdB},
        {to, Call#call.to_header},
        {from, Call#call.from_header},
        {contact, Contact},
        {body, Initiator#participant.sdp}
    ],

    io:format("call_fsm: Request Handle Initiator = ~p, Role = ~p~n", [Initiator#participant.request_handle, Initiator#participant.role]),
    io:format("call_fsm: TargetURI = ~p Contact = ~p~n", [TargetUri, Contact]),

    {async, ReqId} = nksip_uac:invite(AppId, TargetUri, Opts),
    io:format("call_fsm: ReqId = ~p~n", [ReqId]),

    voip_server_core:change_call_id(CallIdB, self()),

    NewInvitedParticipant = InvitedParticipant#participant{request_handle = ReqId},
    NewCall = Call#call{call_id_b = CallIdB, participants = [Initiator, NewInvitedParticipant], state = trying},
    voip_server_db:add_call(NewCall),
    {keep_state, {NewCall, OutgoingInvite}};
%% Пришел 180 Ringing
calling(info, {nksip_uac_reply, _FromPid, {resp, 180, Req, _C}}, {#call{participants = [Initiator, InvitedParticipant]} = Call, OutgoingInvite}) ->
    io:format("call_fsm: calling 180 ringing~n"),
    To = nksip_sipmsg:get_meta(to, Req),
    case nksip_request:reply({180, []}, Initiator#participant.request_handle) of
        ok -> ok;
        {error, Reason} -> io:format("call_fsm: error in reply initiator: ~p~n", [Reason])
    end,

    {ok, OutDialogId} = nksip_dialog:get_handle(Req),
    io:format("call_fsm: OutDialogId = ~p~n", [OutDialogId]),

    %% Вызываемый абонент сгенерировал свой Tag в заголовке TO, сохраняем его в Call для последующих ответов
    NewInvitedParticipant = InvitedParticipant#participant{status = ringing, dialog_handle = OutDialogId},
    NewCall = Call#call{participants = [Initiator, NewInvitedParticipant], state = ringing, to_header = To},
    voip_server_db:add_call(NewCall),
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

    Opts = [
        {body, Body},
        {contact, Contact2}
    ],

    case nksip_request:reply({ok, Opts}, Initiator#participant.request_handle) of
        ok ->
            nksip_uac:ack(InvitedParticipant#participant.dialog_handle, []),        %% TODO обработать
            io:format("call_fsm: successful connection of subscribers ~p and ~p~n", [Initiator#participant.id, InvitedParticipant#participant.id]),
            NewInvitedParticipant = InvitedParticipant#participant{status = active, request_handle = undefined, sdp = Body},
            NewInitiator = Initiator#participant{status = active, request_handle = undefined},

            NewCall = Call#call{participants = [NewInitiator, NewInvitedParticipant], state = active},
            voip_server_db:add_call(NewCall),
            {next_state, active, {NewCall, undefined}};
        {error, Reason} ->
            io:format("call_fsm: error in send reply for initiator: ~p~n", [Reason]),
            nksip_uac:cancel(InvitedParticipant#participant.request_handle, []),
            {stop, normal}
    end;
%% Вызываемый абонент занят - завершаем звонок
%% Отправляем busy вызывающему, вызываемому nksip сам отправит ACK
calling(info, {nksip_uac_reply, _FromPid, {resp, 486, _Req, _C}}, {#call{participants = [Initiator, _InvitedParticipant]}, _OutgoingInvite}) ->
    io:format("call_fsm: 486 busy here~n"),
    case nksip_request:reply({486, []}, Initiator#participant.request_handle) of
        ok -> ok;
        {error, Reason} -> io:format("call_fsm: error in reply initiator: ~p~n", [Reason])
    end,
    {stop, normal};
%% Вызываемый абонент не ответил на звонок
%% Отправляем temporarily_unavailable вызывающему, вызываемому nksip сам отправит ACK
calling(info, {nksip_uac_reply, _FromPid, {resp, 480, _Req, _C}}, {#call{participants = [Initiator, _InvitedParticipant]}, _OutgoingInvite}) ->
    io:format("call_fsm: 480 user not responding~n"),
    case nksip_request:reply({480, []}, Initiator#participant.request_handle) of
        ok -> ok;
        {error, Reason} -> io:format("call_fsm: error in reply initiator: ~p~n", [Reason])
    end,
    {stop, normal};
calling(info, Msg, {_Call, _OutgoingInvite}) ->
    io:format("call_fsm: calling info msg = ~p~n", [Msg]),
    {stop, normal};
%% Шлём CANCEL в диалог вызываемого абонента, если пришёл от вызывающего, и завершаем звонок
%% Вызывающему 200 OK отправит сам nksip
calling(cast, cancel, {#call{participants = [_Initiator, InvitedParticipant]}, _OutgoingInvite}) ->
    io:format("call_fsm: cast cancel in calling~n"),
    Result = nksip_uac:cancel(InvitedParticipant#participant.request_handle, []),
    io:format("call_fsm: send cancel to callee result = ~p~n", [Result]),
    {stop, normal};
%% Вызываемый абонент не отвечает спустя INVITE_TIMEOUT мс
%% Завершаем звонок по 408 Request Timeout
calling(state_timeout, calling_invite_timeout, {#call{participants = [Initiator, InvitedParticipant]}, _OutgoingInvite}) ->
    io:format("call_fsm: the call ended by timeout~n"),
    nksip_uac:cancel(InvitedParticipant#participant.request_handle, []),
    case nksip_request:reply({408, []}, Initiator#participant.request_handle) of
        ok -> ok;
        {error, Reason} -> io:format("call_fsm: error in reply initiator: ~p~n", [Reason])
    end,
    {stop, normal};
calling(EventType, EventContent, Data) ->
    io:format("call_fsm: Unexpected event ~p: ~p~n", [EventType, EventContent]),
    {keep_state, Data}.

%% TODO переводить в terminating при входе в функцию, в terminate/3 переводить в terminated, сохранять в mnesia
%% Поймали сигнал BYE от одного из абонентов на стадии активного звонка
%% Разъединяем абонентов
active(cast, {bye, FromAOR, ToAOR, ReqId}, {Call, _}) ->
    io:format("call_fsm: active cast send BYE message from ~p~n", [FromAOR]),

    ToParticipant = lists:keyfind(ToAOR, #participant.id, Call#call.participants),

    case nksip_uac:bye(ToParticipant#participant.dialog_handle, []) of
        {ok, Code, _} when Code >= 200 andalso Code < 300 ->
            io:format("call_fsm: 200 sending bye to ~p~n", [ToAOR]),
            case nksip_request:reply(200, ReqId) of
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
%% Пришел Re-INVITE запрос
%% Отправляем его второму абоненту и асинхронно обрабатываем ответ 200 OK с новый телом SDP
%% TODO сделать таймер для асинхронного запроса
active(cast, {re_invite, [FromParticipant, _ToParticipant],
#outgoing_invite{target_uri = TargetUri, domain = ServerDomain, port = ServerPort} = OutgoingInvite},
{#call{participants = [Initiator, InvitedParticipant]} = Call, _}) ->
    io:format("call_fsm: active cast re_invite~n"),
    io:format("call_fsm: TargetUri = ~p~n", [TargetUri]),

    %% Абонент, от которого пришел Re-INVITE может быть инициатором или вызываемым
    %% Информация о изначальной роли абонента хранится в поле role записи participant (caller | callee)
    InitiatorAOR = Initiator#participant.id,
    InvitedParticipantAOR = InvitedParticipant#participant.id,
    NewParticipantList = case FromParticipant#participant.id of
        InitiatorAOR ->
            [
                Initiator#participant{request_handle = FromParticipant#participant.request_handle, sdp = FromParticipant#participant.sdp},
                InvitedParticipant
            ];
        InvitedParticipantAOR ->
            [
                InvitedParticipant#participant{request_handle = FromParticipant#participant.request_handle, sdp = FromParticipant#participant.sdp},
                Initiator
            ]
    end,
    [NewInitiator, NewInvitedParticipant] = NewParticipantList,

    {sip, InitiatorName, _} = NewInitiator#participant.id,
    Contact = TargetUri#uri{user = InitiatorName, domain = ServerDomain, port = ServerPort},

    CallIdA = Call#call.call_id_a,
    FsmCallback = fun(Result) ->
        case voip_server_db:get_call(CallIdA) of
            [] ->
                io:format("call_fsm: error in fsm_callback_fun/1: not found call ~p~n", [CallIdA]);
            [ExistCall] ->
                ExistCall#call.fsm_pid ! {nksip_uac_reply, self(), Result}
        end
    end,

    Opts = [
        async,
        {callback, FsmCallback},
        {contact, Contact},
        {body, NewInitiator#participant.sdp}
    ],

    {async, ReqId} = nksip_uac:invite(NewInvitedParticipant#participant.dialog_handle, Opts),
    io:format("call_fsm: ReqId = ~p~n", [ReqId]),

    NewCall = Call#call{participants = [NewInitiator, NewInvitedParticipant]},
    voip_server_db:add_call(NewCall),
    {keep_state, {NewCall, OutgoingInvite}};

active(info, {nksip_uac_reply, _FromPid, {resp, 200, Req, _C}}, {#call{participants = [Initiator, InvitedParticipant]} = Call, OutgoingInvite}) ->
    io:format("call_fsm: 200 OK~n"),
    Body = nksip_sipmsg:get_meta(body, Req),
    [Contact | _Other] = nksip_sipmsg:get_meta(contacts, Req),
    io:format("call_fsm: body = ~p~n", [Body]),

    Contact2 = Contact#uri{domain = OutgoingInvite#outgoing_invite.domain, port = OutgoingInvite#outgoing_invite.port},
    io:format("call_fsm: Contact2 = ~p~n", [Contact2]),

    Opts = [
        {body, Body},
        {contact, Contact2}
    ],

    case nksip_request:reply({ok, Opts}, Initiator#participant.request_handle) of
        ok ->
            nksip_uac:ack(InvitedParticipant#participant.dialog_handle, []),        %% TODO обработать
            io:format("call_fsm: successful connection of subscribers ~p and ~p~n", [Initiator#participant.id, InvitedParticipant#participant.id]),
            NewInvitedParticipant = InvitedParticipant#participant{status = hold, request_handle = undefined, sdp = Body},
            NewInitiator = Initiator#participant{status = active, request_handle = undefined},

            NewCall = Call#call{participants = [NewInitiator, NewInvitedParticipant]},
            voip_server_db:add_call(NewCall),
            {next_state, active, {NewCall, undefined}};
        {error, Reason} ->
            io:format("call_fsm: error in send reply for initiator: ~p~n", [Reason]),
            nksip_uac:cancel(InvitedParticipant#participant.request_handle, []),
            {stop, normal}
    end;

active(info, Msg, {_Call, _OutgoingInvite}) ->
    io:format("call_fsm: active info msg = ~p~n", [Msg]),
    {stop, normal};

active(EventType, EventContent, Data) ->
    io:format("call_fsm: Unexpected event ~p: ~p~n", [EventType, EventContent]),
    io:format("call_fsm: Data: ~p~n", [Data]),
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
        _ -> idle
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
