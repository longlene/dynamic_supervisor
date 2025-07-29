-module(example_usage).

-export([demo/0]).

demo() ->
    io:format("=== Dynamic Supervisor Example Usage ===~n~n"),
    
    %% Start a dynamic supervisor
    io:format("1. Starting dynamic supervisor...~n"),
    {ok, _SupPid} = dynamic_supervisor:start_link([
        {name, {local, my_app_dynamic_supervisor}},
        {strategy, one_for_one},
        {max_restarts, 3},
        {max_seconds, 5}
    ]),
    io:format("   Dynamic supervisor started successfully~n~n"),
    
    %% Start counter children using the counter module
    io:format("2. Starting counter children...~n"),
    
    %% Using full child specification
    {ok, Counter1} = dynamic_supervisor:start_child(my_app_dynamic_supervisor,
        #{id => counter1,
          start => {counter, start_link, [0]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [counter]}),
    io:format("   Started counter1 with initial value 0: ~p~n", [Counter1]),
    io:format("   counter:inc(Counter1) returns: ~p~n", [counter:inc(Counter1)]),
    
    %% Using simplified specification (defaults will be applied)
    {ok, Counter2} = dynamic_supervisor:start_child(my_app_dynamic_supervisor,
        #{id => counter2,
          start => {counter, start_link, [10]}}),
    io:format("   Started counter2 with initial value 10: ~p~n", [Counter2]),
    io:format("   counter:inc(Counter2) returns: ~p~n", [counter:inc(Counter2)]),
    
    %% Check children count
    io:format("~n3. Checking children count...~n"),
    Counts = dynamic_supervisor:count_children(my_app_dynamic_supervisor),
    io:format("   ~p~n", [Counts]),
    
    %% List all children
    io:format("~n4. Listing all children...~n"),
    Children = dynamic_supervisor:which_children(my_app_dynamic_supervisor),
    lists:foreach(fun({Id, Pid, Type, Modules}) ->
        io:format("   Id: ~p, Pid: ~p, Type: ~p, Modules: ~p~n", 
                  [Id, Pid, Type, Modules])
    end, Children),
    
    %% Demonstrate extra_arguments feature
    io:format("~n5. Using extra_arguments feature...~n"),
    {ok, _SupWithExtra} = dynamic_supervisor:start_link([
        {name, {local, sup_with_extra}},
        {strategy, one_for_one},
        {extra_arguments, [shared_config]}
    ]),
    
    %% When starting children, the extra arguments will be prepended
    %% So if counter module accepted config as first argument:
    %% start_child would call counter:start_link(shared_config, 100)
    io:format("   Created supervisor with extra_arguments~n"),
    
    %% Demonstrate restart behavior
    io:format("~n6. Testing restart behavior...~n"),
    {ok, RestartTest} = dynamic_supervisor:start_child(my_app_dynamic_supervisor,
        #{id => restart_test,
          start => {counter, start_link, [999]},
          restart => permanent}),
    io:format("   Created permanent child: ~p~n", [RestartTest]),
    io:format("   Killing child process...~n"),
    exit(RestartTest, kill),
    timer:sleep(100),
    io:format("   Checking children after kill...~n"),
    NewChildren = dynamic_supervisor:which_children(my_app_dynamic_supervisor),
    io:format("   Number of children: ~p~n", [length(NewChildren)]),
    
    %% Terminate a specific child
    io:format("~n7. Terminating a specific child...~n"),
    ok = dynamic_supervisor:terminate_child(my_app_dynamic_supervisor, Counter1),
    io:format("   Counter1 terminated~n"),
    FinalCounts = dynamic_supervisor:count_children(my_app_dynamic_supervisor),
    io:format("   Final counts: ~p~n", [FinalCounts]),
    
    %% Clean up
    io:format("~n8. Stopping supervisors...~n"),
    ok = dynamic_supervisor:stop(my_app_dynamic_supervisor),
    ok = dynamic_supervisor:stop(sup_with_extra),
    io:format("   All supervisors stopped~n~n"),
    
    io:format("=== Example completed successfully! ===~n").