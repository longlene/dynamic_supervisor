-module(notify_proc).
-export([start_link/1]).

start_link(Parent) ->
    Parent ! from_child,
    {ok, spawn_link(fun() -> timer:sleep(60000) end)}.