-module(voip_server_uas).

-export([sip_get_user_pass/4, sip_authorize/3, sip_route/5, sip_register/2, sip_registrar_store/2]).

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
    io:format("voip_server: sip_authorize/3 Method: ~p FromUser: ~p~n", [Method, FromUser]),
    case lists:member(dialog, AuthList) orelse lists:member(register, AuthList) of
        true -> ok;
        false ->
            case proplists:get_value({digest, <<"voip_server">>}, AuthList) of
                true -> ok;
                false -> forbidden;
                undefined -> {proxy_authenticate, <<"voip_server">>}
            end
    end.

sip_route(_Scheme, <<>>, <<"localhost">>, _Req, _Call) ->
    % we want to act as an endpoint or B2BUA
    io:format("voip_server: sip_route(User = <<>>)~n"),
    process;

sip_route(_Scheme, User, _Domain, Req, _Call) ->
    io:format("voip_server: sip_route(User = ~p, Req: ~p)~n", [User, Req]),
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
    case voip_server_db:delete_registration(AOR) of
        ok ->
            ok;
        {error, Reason} ->
            io:format("sip_registrar_store: error del registration: ~p~n", [Reason]),
            not_found
    end;
sip_registrar_store(AppId, del_all = StoreOp) ->
    io:format("sip_registrar_store ~p StoreOp: ~p~n", [AppId, StoreOp]),
    ok.
    % case StoreOp of
    %     {get, AOR} ->
    %         io:format("get aor: ~p~n"),
    %         voip_server_db:get_registrations(AOR);
    %     {put, AOR, Contacts, _TTL} ->

