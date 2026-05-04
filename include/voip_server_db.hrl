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

-record(dialplan, {
    id              :: integer(),
    priority        :: integer(),
    match_pattern   :: binary(),            %% Example: <<"^79\d{9}$">>
    action          :: action(),            %% Example: user - что сделать с запросом
    target          :: binary()             %% Example: <<"user:100">> - куда направить запрос
}).

-define(COUNT_TABLES, 4).

-type user_status() :: active | inactive.
-type action()      :: user | redirect | proxy.
-type timestamp() :: {MegaSecs :: non_neg_integer(), Secs :: non_neg_integer(), MicroSecs :: non_neg_integer()}.
