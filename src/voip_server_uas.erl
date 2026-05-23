-module(voip_server_uas).

-export([sip_get_user_pass/4, sip_authorize/3, sip_route/5, sip_register/2, sip_invite/2, sip_cancel/2, sip_bye/2, sip_registrar_store/2]).
-export([sip_dialog_update/3]).

-include_lib("nksip/include/nksip.hrl").
-include_lib("nklib/include/nklib.hrl").
-include_lib("nksip/include/nksip_registrar.hrl").
-include_lib("nkserver/include/nkserver_module.hrl").
-include_lib("voip_server/include/voip_server_db.hrl").
-include_lib("voip_server/include/voip_server_call_fsm.hrl").

sip_get_user_pass(User, Domain, _Req, _Call) ->
    io:format("voip_server: sip_get_user_pass(~p, ~p)~n", [User, Domain]),
    case voip_server_db:get_user(User, Domain) of
        {ok, FoundedUser} ->
            FoundedUser#users.password;
        Error ->
            io:format("voip_server: error in sip_get_user_pass: ~p~n", [Error]),
            false
    end.

sip_authorize(AuthList, Req, _Call) ->
    Method = nksip_sipmsg:get_meta(method, Req),
    FromUser = nksip_sipmsg:get_meta(from_user, Req),
    FromDomain = nksip_sipmsg:get_meta(from_domain, Req),
    io:format("voip_server: sip_authorize/3 Method: ~p FromUser: ~p~n", [Method, FromUser]),
    case lists:member(dialog, AuthList) orelse lists:member(register, AuthList) of
        true -> ok;
        false ->
            case proplists:get_value({digest, FromDomain}, AuthList) of
                true -> ok;
                false -> forbidden;
                undefined -> {proxy_authenticate, FromDomain}
            end
    end.

sip_route(_Scheme, <<>>, <<"localhost">>, _Req, _Call) ->
    % we want to act as an endpoint or B2BUA
    io:format("voip_server: sip_route(User = <<>>)~n"),
    process;

sip_route(_Scheme, User, Domain, Req, _Call) ->
    io:format("voip_server: sip_route(User = ~p, Domain: ~p)~n", [User, Domain]),
    case nksip_request:is_local_ruri(Req) of
        true ->
            process;
        false ->
            proxy
    end.

sip_register(Req, _Call) ->
    {ok, [{from_scheme, FromScheme}, {from_user, FromUser}, {from_domain, FromDomain}]} =
        nksip_request:get_metas([from_scheme, from_user, from_domain], Req),
    {ok, [{to_scheme, ToScheme}, {to_user, ToUser}, {to_domain, ToDomain}]} =
        nksip_request:get_metas([to_scheme, to_user, to_domain], Req),

    io:format("voip_server: sip_register(From ~p)~n", [FromUser]),
    case {FromScheme, FromUser, FromDomain} of
        {ToScheme, ToUser, ToDomain} ->
            io:format("REGISTER OK: ~p~n", [{ToUser, ToDomain}]),
            {reply, nksip_registrar:request(Req)};
        _ ->
            {reply, forbidden}
    end.

sip_invite(Req, Call) ->
    {ok, [{from_user, FromUser}, {from_domain, FromDomain}, {to_user, ToUser}, {call_id, CallId}, {to_domain, ToDomain}]} =
        nksip_request:get_metas([from_user, from_domain, to_user, call_id, to_domain], Req),

    case voip_server_db:get_registrations(FromUser, FromDomain) of
        [] ->
            io:format("voip_server: User ~s@~s is not registered~n", [FromUser, FromDomain]),
            {reply, 480};
        _ ->
            {ok, ReqId} = nksip_request:get_handle(Req),

            {ok, InDialogId} = nksip_dialog:get_handle(Req),
            io:format("voip_server: InDialogId = ~p~n", [InDialogId]),

            io:format("voip_server: INVITE from ~s@~s to ~s@~s (Call-ID: ~s)~n", [FromUser, FromDomain, ToUser, ToDomain, CallId]),

            case voip_server_db:get_user(ToUser, ToDomain) of
                {error, not_found} ->
                    io:format("voip_server: User ~s@~s not found~n", [ToUser, ToDomain]),
                    {reply, 404};
                {ok, _ToUserRec} ->
                    case voip_server_db:get_registrations(ToUser, ToDomain) of
                        [] ->
                            io:format("voip_server: User ~s@~s is not registered~n", [ToUser, ToDomain]),
                            {reply, 480};
                        Contacts when is_list(Contacts) ->
                            AppId = nksip_call:srv_id(Call),
                            CallId = nksip_call:call_id(Call),
                            %% TODO: сделать очередь по приоритетам дозвона
                            [#registrations{reg_contact = RegContact} | _Rest] = Contacts,
                            TargetUri = RegContact#reg_contact.contact,

                            FromHeader = nksip_sipmsg:get_meta(from, Req),
                            ToHeader = nksip_sipmsg:get_meta(to, Req),
                            Body = nksip_sipmsg:get_meta(body, Req),
                            #uri{domain = ServerDomain, port = ServerPort} = nksip_sipmsg:get_meta(ruri, Req),
                            ServerPort2 = case ServerPort of
                                0 -> 5060;
                                Int -> Int
                            end,

                            InParticipantMap = #{
                                ?USER_NAME      => FromUser,
                                ?DOMAIN_NAME    => FromDomain,
                                ?ROLE           => caller,
                                ?REQUEST_HANDLE => ReqId,
                                ?DIALOG_HANDLE  => InDialogId,
                                ?SDP            => Body
                            },
                            OutParticipantMap = #{
                                ?USER_NAME      => ToUser,
                                ?DOMAIN_NAME    => ToDomain,
                                ?ROLE           => callee
                            },
                            OutgoingInvite = #outgoing_invite{
                                target_uri  = TargetUri,
                                serv_id     = AppId,
                                from        = FromHeader,
                                to          = ToHeader,
                                domain      = ServerDomain,
                                port        = ServerPort2
                            },

                            io:format("voip_server: Start call ~p~n", [CallId]),
                            voip_server_core:create_call({CallId, [InParticipantMap, OutParticipantMap], OutgoingInvite}),

                            noreply
                    end
            end
    end.

sip_cancel(Req, _Call) ->
    {ok, [{call_id, CallId}]} = nksip_request:get_metas([call_id], Req),
    io:format("voip_server: CANCEL received for Call-ID: ~p~n", [CallId]),
    {forward}.

sip_bye(Req, _Call) ->
    {ok, [{from_user, FromUser}, {from_domain, FromDomain}, {to_user, ToUser}, {call_id, CallId}, {to_domain, ToDomain}]} =
        nksip_request:get_metas([from_user, from_domain, to_user, call_id, to_domain], Req),
    {ok, ReqId} = nksip_request:get_handle(Req),
    io:format("voip_server: BYE received for call ~p~n", [CallId]),
    voip_server_core:send_bye({CallId, FromUser, FromDomain, ToUser, ToDomain, ReqId}),
    noreply.

sip_registrar_store(AppId, {get, AOR} = StoreOp) ->
    io:format("sip_registrar_store ~p StoreOp: ~p~n", [AppId, StoreOp]),
    voip_server_db:get_registrations({registrations, AOR});
sip_registrar_store(AppId, {put, AOR, [RegContact], _TTL} = StoreOp) ->
    io:format("sip_registrar_store ~p StoreOp: ~p~n", [AppId, StoreOp]),
    case voip_server_db:add_registration(AOR, RegContact) of
        ok ->
            ok;
        {error, Reason} ->
            io:format("sip_registrar_store: error add registration: ~p~n", [Reason]),
            ok
    end;
sip_registrar_store(AppId, {del, AOR} = StoreOp) ->
    io:format("sip_registrar_store ~p StoreOp: ~p~n", [AppId, StoreOp]),
    case voip_server_db:delete_registrations(AOR) of
        ok ->
            ok;
        {error, Reason} ->
            io:format("sip_registrar_store: error del registration: ~p~n", [Reason]),
            not_found
    end;
sip_registrar_store(AppId, del_all = StoreOp) ->
    io:format("sip_registrar_store ~p StoreOp: ~p~n", [AppId, StoreOp]),
    case voip_server_db:clear_registrations() of
        ok ->
            ok;
        {error, Reason} ->
            io:format("sip_registrar_store: error del_all registration: ~p~n", [Reason]),
            ok
    end.

sip_dialog_update({invite_status,{stop,cancelled}}, D, _Call) ->
    io:format("voip_server: call sip_dialog_update~n"),

    CallId = D#dialog.call_id,
    io:format("voip_server: call_id = ~p~n", [CallId]),

    #uri{user = FromUser, domain = FromDomain} = D#dialog.local_uri,
    #uri{user = ToUser, domain = ToDomain} = D#dialog.remote_uri,
    io:format("voip_server: stop dialog between ~p@~p and ~p@~p~n", [FromUser, FromDomain, ToUser, ToDomain]),

    voip_server_core:send_cancel(CallId),
    ok;
sip_dialog_update(DS, D, _Call) ->
    io:format("voip_server: call sip_dialog_update~n"),
    io:format("voip_server: DS = ~p~n", [DS]),
    io:format("voip_server: call_id = ~p~n", [D#dialog.call_id]),
    ok.
