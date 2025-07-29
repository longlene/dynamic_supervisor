-module(return_test_worker).
-export([start_link/1]).

start_link(ok3) ->
    {ok, spawn_link(fun() -> timer:sleep(infinity) end), extra};
start_link(ok2) ->
    {ok, spawn_link(fun() -> timer:sleep(infinity) end)};
start_link(error) ->
    {error, found};
start_link(ignore) ->
    ignore;
start_link(unknown) ->
    unknown;
start_link(throw_error) ->
    throw(oops);
start_link(raise_error) ->
    error(oops);
start_link(exit_error) ->
    exit(oops).