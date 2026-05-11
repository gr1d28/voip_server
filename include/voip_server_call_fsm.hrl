-record(outgoing_invite, {
    target_uri      :: nksip:uri(),
    serv_id         :: nkserver:id(),
    from            :: nksip:uri(),
    to              :: nksip:uri(),
    domain          :: binary(),
    port            :: non_neg_integer()
}).

-define(USER_NAME, user).
-define(DOMAIN_NAME, domain).
-define(ROLE, role).
-define(REQUEST_HANDLE, request_handle).
-define(DIALOG_HANDLE, dialog_handle).
-define(SDP, sdp).

-type participant_map() :: #{
    ?USER_NAME      => binary(),
    ?DOMAIN_NAME    => binary(),
    ?ROLE           => voip_server_db:participant_role(),
    ?REQUEST_HANDLE => nksip:handle() | undefined,
    ?DIALOG_HANDLE  => nksip:handle() | undefined,
    ?SDP            => nksip:body() | undefined
}.
-type participant_list() :: [participant_map()].
-type outgoing_invite() :: #outgoing_invite{}.
