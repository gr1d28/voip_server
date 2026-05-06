-module(voip_server_uas).

-export([sip_get_user_pass/4, sip_authorize/3, sip_route/5, sip_register/2, sip_invite/2, sip_cancel/2, sip_bye/2, sip_registrar_store/2]).

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
                    %% TODO: сделать очередь по приоритетам дозвона
                    [#registrations{reg_contact = RegContact} | _Rest] = Contacts,
                    TargetUri = RegContact#reg_contact.contact,

                    % nksip_uac:invite(voip_server_uas, UriRecord, [auto_2xx_ack]),
                    % {reply, 200}
                    Body = nksip_sipmsg:get_meta(body, Req),

                    spawn(fun() -> b2bua_outgoing(Call, TargetUri, Body) end),

                    noreply

                    % Очищаем URI от параметров контакта (expires и т.д.)
                    % CleanUri = UriRecord#uri{
                    %     opts = [],
                    %     headers = [],
                    %     ext_opts = [],
                    %     ext_headers = []
                    % },

                    % % Преобразуем запись обратно в бинарную строку для {proxy, ...}
                    % % Используем nklib_unparse:uri/1, но нам нужно убрать скобки <> если они есть
                    % RawUriBin = nklib_unparse:uri(CleanUri),

                    % % nklib_unparse:uri возвращает <<"<sip:...>">>, убираем скобки для чистоты,
                    % % хотя {proxy, ...} часто принимает и со скобками, но лучше без них для SIP URI в теле маршрута
                    % % Удаляем угловые скобки < > вручную, если они есть
                    % UriBin = case RawUriBin of
                    %     <<"<", Bin/binary>> ->
                    %         % Если начинается с <, убираем его и последний символ (>)
                    %         Len = (byte_size(Bin) - 1),
                    %         case Bin of
                    %             <<Result:Len/binary, ">">> -> Result;
                    %             _ -> Bin % Если закрывающей скобки нет, оставляем как есть
                    %         end;
                    %     _ ->
                    %         RawUriBin
                    % end,

                    % io:format("voip_server: Proxying INVITE to: ~s~n", [UriBin]),

                    % % ВАЖНО: используем {proxy, UriBin} вместо {forward, ...}
                    % {proxy, UriBin}
            end
    end.

sip_cancel(Req, _Call) ->
    {ok, [{call_id, CallId}]} = nksip_request:get_metas([call_id], Req),
    io:format("voip_server: CANCEL received for Call-ID: ~p~n", [CallId]),
    {forward}.

sip_bye(Req, _Call) ->
    {ok, CallId} = nksip_sipmsg:get_meta(call_id, Req),
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

b2bua_outgoing(InCall, TargetUri, _Body) ->
    AppId = nksip_call:srv_id(InCall),
    Opts = [{async, true}],
    InCallId = nksip_call:call_id(InCall),

    io:format("voip_server: InCallId = ~p~n", [InCallId]),
    io:format("voip_server: Sending INVITE to ~p with SDP~n", [TargetUri]),

    case nksip_call:send(AppId, InCallId, 'INVITE', TargetUri, Opts) of
        {ok, OutCall} ->
            % OutCallId = nksip_call:call_id(OutCall),
            io:format("voip_server: Outgoing call created: ~p~n", [OutCall]),
            ok;
            % Сохраняем связь между вызовами
            % ets:insert(?CALL_MAP, {InCallId, {OutCall, InCall}}),
            % ets:insert(?CALL_MAP, {OutCallId, {InCall, OutCall}});
        {error, Reason} ->
            io:format("voip_server: Failed to create outgoing call: ~p~n", [Reason]),
            % Если не удалось дозвониться, можно отправить ошибку во входящий вызов
            % nksip_call:send_reply(InCall, 503, [], [])
            ok;
        Answer ->
            io:format("Answer nksip_call:send = ~p~n", [Answer]),
            ok
    end.

% sip_invite(Req, InCall) ->
%     {ok, [{from_user, FromUser}, {from_domain, FromDomain}, {to_user, ToUser}, {call_id, CallId}, {to_domain, ToDomain}]} =
%         nksip_request:get_metas([from_user, from_domain, to_user, call_id, to_domain], Req),

%     io:format("voip_server: INVITE from ~s@~s to ~s@~s (Call-ID: ~s)~n", [FromUser, FromDomain, ToUser, ToDomain, CallId]),

%     case voip_server_db:get_user(ToUser, ToDomain) of
%         {error, not_found} ->
%             {reply, {404, []}};
%         {ok, _ToUserRec} ->
%             case voip_server_db:get_registrations(ToUser, ToDomain) of
%                 [] ->
%                     {reply, {480, []}};
%                 Contacts when is_list(Contacts) ->
%                     [#registrations{reg_contact = RegContact} | _Rest] = Contacts,
%                     UriRecord = RegContact#reg_contact.contact,
                    
%                     % Очищаем URI от параметров регистрации (expires), оставляя только адрес
%                     CleanUri = UriRecord#uri{opts = [], headers = [], ext_opts = [], ext_headers = []},
                    
%                     % Получаем SDP из входящего запроса
%                     Body = nksip_sipmsg:get_meta(body, Req),
                    
%                     io:format("voip_server: Starting B2BUA to ~p~n", [CleanUri]),
                    
%                     % Запускаем исходящий вызов асинхронно
%                     % Важно: передаем SDP и callback для обработки ответов
%                     AppId = nksip_call:srv_id(InCall),
%                     InCallId = nksip_call:call_id(InCall),
                    
%                     % Сохраняем состояние, что мы ждем ответа для этого вызова
%                     % В реальном проекте лучше использовать ETS или Mnesia
%                     put({b2bua_pending, InCallId}, {outgoing_init, CleanUri, Body}),
                    
%                     Opts = [
%                         {async, true}, 
%                         {body, Body}, 
%                         {callback, fun b2bua_callback/2} % Колбэк для событий исходящего вызова
%                     ],
                    
%                     case nksip_call:send(AppId, InCallId, 'INVITE', CleanUri, Opts) of
%                         {ok, OutCall} ->
%                             OutCallId = nksip_call:call_id(OutCall),
%                             io:format("voip_server: Outgoing call created: ~p, linking with ~p~n", [OutCallId, InCallId]),
                            
%                             % Сохраняем связь вызовов в процессе или ETS
%                             % Ключ: {b2bua_link, CallId}, Значение: {InCall, OutCall}
%                             put({b2bua_link, InCallId}, {InCall, OutCall}),
%                             put({b2bua_link, OutCallId}, {OutCall, InCall}),
                            
%                             % Возвращаем noreply, так как будем отвечать вручную через колбэки
%                             noreply;
%                         {error, Reason} ->
%                             io:format("voip_server: Failed to create outgoing call: ~p~n", [Reason]),
%                             {reply, {503, []}}
%                     end
%             end
%     end.

% Обработка событий исходящего вызова (UAC часть B2BUA)
% b2bua_callback(Req, Call) ->
%     CallId = nksip_call:call_id(Call),
    
%     % Находим связанный вызов
%     case get({b2bua_link, CallId}) of
%         undefined ->
%             io:format("voip_server: B2BUA link not found for ~p~n", [CallId]),
%             noreply;
%         {Call, PeerCall} -> % Call - это текущий (исходящий), PeerCall - тот, куда шлем ответ
%             Method = nksip_sipmsg:get_meta(method, Req),
            
%             if 
%                 Method == 'INVITE' ->
%                     % Проверяем код ответа (он хранится в мета-данных сообщения или можно получить из статуса диалога)
%                     % В nksip v0.6 статус ответа часто передается через аргументы колбэка или meta
%                     % Но в стандартном sip_reply колбэке мы получаем Request с кодом? 
%                     % Нет, в async режиме колбэк вызывается для разных событий.
%                     % Для упрощения в v0.6 часто используют обработку через sip_reply или специфичные meta.
                    
%                     % Попытка получить код ответа из Req (если это ответ)
%                     case nksip_sipmsg:get_meta(status, Req) of
%                         undefined -> 
%                             % Возможно это промежуточное событие, игнорируем или логируем
%                             noreply;
%                         Code when Code >= 100, Code < 200 ->
%                             % Провизорный ответ (180 Ringing)
%                             io:format("voip_server: Received ~p, forwarding to peer~n", [Code]),
%                             nksip_call:send_reply(PeerCall, Code, [], []),
%                             noreply;
%                         200 ->
%                             % Успешный ответ (200 OK)
%                             io:format("voip_server: Received 200 OK, forwarding to peer and sending ACK~n"),
                            
%                             % 1. Извлекаем SDP из ответа
%                             SdpBody = nksip_sipmsg:get_meta(body, Req),
                            
%                             % 2. Отправляем 200 OK во входящий вызов (PeerCall) с SDP
%                             nksip_call:send_reply(PeerCall, 200, [{body, SdpBody}], []),
                            
%                             % 3. ВАЖНО: Отправляем ACK в исходящий вызов (Call), чтобы подтвердить 200 OK
%                             % В nksip_call:send можно отправить ACK явно
%                             AppId = nksip_call:srv_id(Call),
%                             PeerCallId = nksip_call:call_id(PeerCall), % Нам нужен ID диалога, но ACK шлется в рамках того же вызова
                            
%                             % Отправка ACK
%                             nksip_call:send(AppId, Call, 'ACK', [], []), 
                            
%                             noreply;
%                         Code when Code >= 300 ->
%                             % Ошибка или отказ
%                             io:format("voip_server: Received error ~p, forwarding to peer~n", [Code]),
%                             nksip_call:send_reply(PeerCall, Code, [], []),
%                             noreply
%                     end;
%                 Method == 'BYE' ->
%                     % Если пришла BYE от одной стороны, шлем BYE другой
%                     io:format("voip_server: Received BYE from ~p, sending to peer~n", [CallId]),
%                     nksip_call:send(nksip_call:srv_id(PeerCall), PeerCall, 'BYE', [], []),
%                     {reply, {200, []}}; % Отвечаем 200 на BYE
%                 true ->
%                     noreply
%             end
%     end.

% sip_bye(Req, Call) ->
%     CallId = nksip_call:call_id(Call),
%     io:format("voip_server: BYE received for call ~s~n", [CallId]),
    
%     case get({b2bua_link, CallId}) of
%         {_, PeerCall} ->
%             % Шлем BYE второй стороне
%             catch nksip_call:send(nksip_call:srv_id(PeerCall), PeerCall, 'BYE', [], []);
%         undefined ->
%             ok
%     end,
    
%     {reply, {200, []}}.
