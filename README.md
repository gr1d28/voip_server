voip_server
=====

An OTP application

Build
-----

    $ rebar3 compile

<!-- https://mermaid.js.org/syntax/sequenceDiagram.html -->

```mermaid
sequenceDiagram
    actor pa as A
    participant VoIP-server as uas
    actor pb as B

    Note over pa,VoIP-server: Диалог 1: Вызов от A к серверу
    pa ->> VoIP-server: SIP signal for B
    Note over VoIP-server,pb: Диалог 2: Перенаправление к B
    VoIP-server ->> pb: SIP signal for B
    Note over VoIP-server,pb: Диалог 2: Ответ от B к серверу
    pb ->> VoIP-server: SIP answer for A
    Note over pa,VoIP-server: Диалог 1: Передача отета A
    VoIP-server ->> pa: SIP answer for A
```

<!-- https://mermaid.js.org/syntax/sequenceDiagram.html -->

```mermaid
graph TD;
    Supervisor--Static-->NkSIP;
    Supervisor --Static--> Core;
    Core -.Dynamic.-> Call_FSM1;
    Core -.Dynamic.-> Call_FSM2;
```

<!-- https://mermaid.js.org/syntax/sequenceDiagram.html -->

```mermaid
flowchart LR
    SIP-server --> Core;
    Database@{shape: cyl, label: "Database"} --> Core;
    Core --> Call_FSM;
    Call_FSM --> Database
```