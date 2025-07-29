-module(test_worker).
-export([start_link/0, init/0]).

start_link() ->
    {ok, spawn_link(fun init/0)}.

init() ->
    loop().

loop() ->
    receive
        {stop, Reason} -> exit(Reason);
        _ -> loop()
    end.