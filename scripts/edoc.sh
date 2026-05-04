#!/bin/sh

erl -noshell -run edoc_run files '["../src/poll_db.erl", "../src/poll_report.erl", "../src/poll_uas.erl", "../src/poll_handler.erl"]' '[{dir, "../doc"}]' -s init stop
