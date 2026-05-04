#!/bin/bash

cookie=$(cat ~/.erlang.cookie)
docker exec -it server erl -name mynode@172.30.0.1 -remsh server_node@172.30.0.2 -setcookie "$cookie"
