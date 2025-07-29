-module(sleepy_proc).
-export([start_link/0]).

start_link() ->
    {ok, spawn_link(fun() -> timer:sleep(60000) end)}.