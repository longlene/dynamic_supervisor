-module(test_dynamic_supervisor).

-export([test_all/0]).
-export([test_basic/0, test_restart_strategies/0, test_max_children/0]).

%% Sample worker for testing
-export([start_worker/1, init_worker/1]).

test_all() ->
    io:format("Running Dynamic Supervisor Tests...~n"),
    test_basic(),
    test_restart_strategies(),
    test_max_children(),
    io:format("All tests completed!~n").

test_basic() ->
    io:format("~n=== Basic Functionality Test ===~n"),
    
    %% Start a dynamic supervisor with name as first parameter
    {ok, Sup} = dynamic_supervisor:start_link({local, test_supervisor}, [
        {strategy, one_for_one},
        {max_restarts, 3},
        {max_seconds, 5}
    ]),
    io:format("Started supervisor: ~p~n", [Sup]),
    
    %% Start a child
    ChildSpec = #{
        id => worker1,
        start => {?MODULE, start_worker, [worker1]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [?MODULE]
    },
    {ok, Pid1} = dynamic_supervisor:start_child(test_supervisor, ChildSpec),
    io:format("Started child worker1: ~p~n", [Pid1]),
    
    %% Check children
    Children = dynamic_supervisor:which_children(test_supervisor),
    io:format("Current children: ~p~n", [Children]),
    
    %% Count children
    Counts = dynamic_supervisor:count_children(test_supervisor),
    io:format("Child counts: ~p~n", [Counts]),
    
    %% Start another child using simplified spec
    {ok, Pid2} = dynamic_supervisor:start_child(test_supervisor, 
        #{id => worker2,
          start => {?MODULE, start_worker, [worker2]}}),
    io:format("Started child worker2: ~p~n", [Pid2]),
    
    %% Check updated counts
    UpdatedCounts = dynamic_supervisor:count_children(test_supervisor),
    io:format("Updated child counts: ~p~n", [UpdatedCounts]),
    
    %% Terminate a child
    ok = dynamic_supervisor:terminate_child(test_supervisor, Pid1),
    io:format("Terminated child worker1~n"),
    
    %% Final counts
    FinalCounts = dynamic_supervisor:count_children(test_supervisor),
    io:format("Final child counts: ~p~n", [FinalCounts]),
    
    %% Stop the supervisor
    ok = dynamic_supervisor:stop(test_supervisor),
    io:format("Stopped supervisor~n").

test_restart_strategies() ->
    io:format("~n=== Restart Strategies Test ===~n"),
    
    %% Start supervisor
    {ok, _Sup} = dynamic_supervisor:start_link({local, restart_test_sup}, [
        {strategy, one_for_one},
        {max_restarts, 5},
        {max_seconds, 10}
    ]),
    
    %% Test permanent restart
    io:format("~nTesting permanent restart...~n"),
    {ok, Pid1} = dynamic_supervisor:start_child(restart_test_sup,
        #{id => perm_worker,
          start => {?MODULE, start_worker, [perm_worker]},
          restart => permanent}),
    io:format("Started permanent worker: ~p~n", [Pid1]),
    
    %% Kill the worker
    exit(Pid1, kill),
    timer:sleep(100),
    
    %% Check if restarted
    Children1 = dynamic_supervisor:which_children(restart_test_sup),
    io:format("Children after kill: ~p~n", [Children1]),
    
    %% Test temporary restart
    io:format("~nTesting temporary restart...~n"),
    {ok, Pid2} = dynamic_supervisor:start_child(restart_test_sup,
        #{id => temp_worker,
          start => {?MODULE, start_worker, [temp_worker]},
          restart => temporary}),
    io:format("Started temporary worker: ~p~n", [Pid2]),
    
    %% Kill the temporary worker
    exit(Pid2, kill),
    timer:sleep(100),
    
    %% Check children (temporary should not restart)
    Children2 = dynamic_supervisor:which_children(restart_test_sup),
    io:format("Children after killing temporary: ~p~n", [Children2]),
    
    %% Test transient restart
    io:format("~nTesting transient restart...~n"),
    {ok, Pid3} = dynamic_supervisor:start_child(restart_test_sup,
        #{id => trans_worker,
          start => {?MODULE, start_worker, [trans_worker]},
          restart => transient}),
    io:format("Started transient worker: ~p~n", [Pid3]),
    
    %% Normal exit (should not restart)
    Pid3 ! stop,
    timer:sleep(100),
    
    Children3 = dynamic_supervisor:which_children(restart_test_sup),
    io:format("Children after normal exit of transient: ~p~n", [Children3]),
    
    %% Stop supervisor
    ok = dynamic_supervisor:stop(restart_test_sup),
    io:format("Stopped restart test supervisor~n").

test_max_children() ->
    io:format("~n=== Max Children Test ===~n"),
    
    %% Start supervisor with max_children limit
    {ok, _Sup} = dynamic_supervisor:start_link({local, limited_sup}, [
        {strategy, one_for_one},
        {max_children, 3}
    ]),
    
    %% Start children up to the limit
    lists:foreach(
        fun(N) ->
            Id = list_to_atom("worker" ++ integer_to_list(N)),
            {ok, Pid} = dynamic_supervisor:start_child(limited_sup,
                #{id => Id,
                  start => {?MODULE, start_worker, [Id]}}),
            io:format("Started child ~p: ~p~n", [Id, Pid])
        end,
        [1, 2, 3]
    ),
    
    %% Try to start one more (should fail)
    Result = dynamic_supervisor:start_child(limited_sup,
        #{id => worker4,
          start => {?MODULE, start_worker, [worker4]}}),
    io:format("Attempt to start 4th child: ~p~n", [Result]),
    
    %% Check counts
    Counts = dynamic_supervisor:count_children(limited_sup),
    io:format("Child counts: ~p~n", [Counts]),
    
    %% Stop supervisor
    ok = dynamic_supervisor:stop(limited_sup),
    io:format("Stopped limited supervisor~n").

%% Simple worker implementation
start_worker(Name) ->
    spawn_link(fun() -> init_worker(Name) end).

init_worker(Name) ->
    io:format("Worker ~p started with pid ~p~n", [Name, self()]),
    worker_loop(Name).

worker_loop(Name) ->
    receive
        stop ->
            io:format("Worker ~p stopping normally~n", [Name]),
            ok;
        _Other ->
            worker_loop(Name)
    end.