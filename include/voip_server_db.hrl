-record(users, {
    name            :: binary(),            %% Example: <<"100">>
    domain          :: binary(),            %% Example: <<"test.domain.com">>
    password        :: binary(),            %% Example: <<"$AQbMEm3y$A1wiSc51Nef2r2rSeFDSV1">>
    display_name    :: binary(),            %% Example: <<"Alice">>
    status          :: user_status()
}).

-record(registrations, {
    aor             :: nksip:aor(),         %% Address of Record (user@domain)
    reg_contact     :: nksip_registrar_lib:reg_contact()
}).

-record(participant, {
    id              :: nksip:aor(),                  %% Внутренний ID (например, <<"101">>)
    role            :: participant_role(),
    status          :: participant_status(),
    request_handle  :: nksip:handle(),          %% Transaction Handle (nksip:handle())
    dialog_handle   :: nksip:handle(),       %% Dialog Handle (D_...)
    sdp             :: nksip:body()                  %% Последний согласованный SDP
}).

-record(call, {
    call_id         :: nksip:call_id(),
    fsm_pid         :: pid(),
    participants    :: [#participant{}],
    state           :: call_state(),
    start_time      :: timestamp()
    %% conference_id
}).

-record(dialplan, {
    id              :: integer(),
    priority        :: integer(),
    match_pattern   :: binary(),            %% Example: <<"^79\d{9}$">>
    action          :: action(),            %% Example: user - что сделать с запросом
    target          :: binary()             %% Example: <<"user:100">> - куда направить запрос
}).

-define(COUNT_TABLES, 5).                   %% Tables + Scheme
-define(TABLES_NAME_LIST, [users, registrations, call, dialplan]).

-type user_status() :: active | inactive.
-type action()      :: user | redirect | proxy.
-type timestamp() :: {MegaSecs :: non_neg_integer(), Secs :: non_neg_integer(), MicroSecs :: non_neg_integer()}.
-type call_state() :: initializing | ringing | active | terminating | terminated.
-type participant_status() :: idle | inviting | ringing | active | hold | terminated.
-type participant_role() :: caller | callee.
