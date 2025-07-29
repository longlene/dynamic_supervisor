-module(crash_worker).
-export([start_link/0]).

start_link() ->
    {ok, spawn_link(fun() -> exit(crash) end)}.