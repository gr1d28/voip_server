-module(voip_server_uas).

-export([sip_get_user_pass/4, sip_authorize/3, sip_route/5, sip_register/2, sip_invite/2, sip_ack/2, sip_cancel/2, sip_bye/2, sip_registrar_store/2]).

-include_lib("nklib/include/nklib.hrl").
-include_lib("nksip/include/nksip_registrar.hrl").
-include_lib("nkserver/include/nkserver_module.hrl").
-include_lib("voip_server/include/voip_server_db.hrl").

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

    {ok, ReqId} = nksip_request:get_handle(Req),

    io:format("voip_server: INVITE from ~s@~s to ~s@~s (Call-ID: ~s)~n", [FromUser, FromDomain, ToUser, ToDomain, CallId]),

    io:format("voip_sever: ReqId = ~p~n", [ReqId]),

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
                    %% TODO: сделать очередь по приоритетам дозвона
                    [#registrations{reg_contact = RegContact} | _Rest] = Contacts,
                    TargetUri = RegContact#reg_contact.contact,

                    FromHeader = nksip_sipmsg:get_meta(from, Req),
                    [ContactHeader | _OtherContacts] = nksip_sipmsg:get_meta([<<"contact">>], Req), %% может вернуть несколько contact
                    Body = nksip_sipmsg:get_meta(body, Req),
                    io:format("Original From = ~p~n Original Contact = ~p~n", [FromHeader, ContactHeader]),
                    io:format("Body = ~p~n", [Body]),

                    spawn(fun() -> b2bua_outgoing(Call, TargetUri, Body, ReqId, FromHeader, ContactHeader) end),

                    noreply
            end
    end.

sip_ack(Req, _Call) ->
    CallId = nksip_sipmsg:get_meta(call_id, Req),
    io:format("voip_server: ACK received for call ~s~n", [CallId]),
    {reply, ok}.

sip_cancel(Req, _Call) ->
    {ok, [{call_id, CallId}]} = nksip_request:get_metas([call_id], Req),
    io:format("voip_server: CANCEL received for Call-ID: ~p~n", [CallId]),
    {forward}.

sip_bye(Req, _Call) ->
    CallId = nksip_sipmsg:get_meta(call_id, Req),
    io:format("voip_server: BYE received for call ~s~n", [CallId]),
    {reply, {200, []}}.

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

b2bua_outgoing(InDialog, TargetUri, Body, InReqId, OriginalFrom, OriginalContact) ->
    AppId = nksip_call:srv_id(InDialog),
    CallId = nksip_call:call_id(InDialog),

    io:format("voip_server: Incoming Call-ID: ~p~n", [CallId]),
    io:format("voip_server: Sending INVITE to ~p with SDP~n", [TargetUri]),

    Opts = [
        {call_id, CallId},
        {from, OriginalFrom},
        {contact, OriginalContact},
        {body, Body},
        {get_meta, [body]},
        auto_2xx_ack,
        {timeout, 60000}
    ],

    nksip_request:reply(ringing, InReqId),

    case nksip_uac:invite(AppId, TargetUri, Opts) of
        {ok, Code, OutDialogHandle} when Code >= 200 andalso Code < 300 ->
            io:format("voip_server: Outgoing call answered immediately with ~p~n", [Code]),
            io:format("OutDialogHandle = ~p~n", [OutDialogHandle]),
            % {dialog, DialogHandle} = lists:keyfind(dialog, 1, OutDialogHandle),
            RemoteBody = lists:keyfind(body, 1, OutDialogHandle),
            io:format("voip_server: RemoteBody = ~p~n", [RemoteBody]),
            {body, SDPStruct} = RemoteBody,
            SDPBinary = nksip_sdp:unparse(SDPStruct),
            nksip_request:reply({ok, [
                {body, SDPBinary},
                {contact, <<"sip:100@172.40.0.2:5060">>},
                {content_type, <<"application/sdp">>}
            ]}, InReqId),
            ok;
        {error, Reason} ->
            io:format("voip_server: Failed to create outgoing call: ~p~n", [Reason]),
            ok;
        Answer ->
            io:format("voip_server: Unexpected answer: ~p~n", [Answer]),
            ok
    end.
