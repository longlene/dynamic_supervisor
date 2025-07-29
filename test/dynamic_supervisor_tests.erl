-module(dynamic_supervisor_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test fixture
setup() ->
    {ok, Pid} = dynamic_supervisor:start_link([
        {strategy, one_for_one},
        {max_restarts, 3},
        {max_seconds, 5}
    ]),
    Pid.

teardown(Pid) ->
    dynamic_supervisor:stop(Pid).

dynamic_supervisor_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
      fun test_start_child/1,
      fun test_terminate_child/1,
      fun test_which_children/1,
      fun test_count_children/1,
      fun test_max_children/1,
      fun test_restart_permanent/1,
      fun test_restart_temporary/1,
      fun test_restart_transient/1
     ]}.

test_start_child(Sup) ->
    fun() ->
        %% Test starting a child
        ChildSpec = #{
            id => test_worker,
            start => {test_worker, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [test_worker]
        },
        {ok, Pid} = dynamic_supervisor:start_child(Sup, ChildSpec),
        ?assert(is_pid(Pid)),
        ?assert(is_process_alive(Pid))
    end.

test_terminate_child(Sup) ->
    fun() ->
        %% Start a child first
        {ok, Pid} = dynamic_supervisor:start_child(Sup, 
            #{id => test_worker,
              start => {test_worker, start_link, []}}),
        
        %% Terminate it
        ?assertEqual(ok, dynamic_supervisor:terminate_child(Sup, Pid)),
        
        %% Verify it's gone
        ?assertEqual({error, not_found}, dynamic_supervisor:terminate_child(Sup, Pid))
    end.

test_which_children(Sup) ->
    fun() ->
        %% Initially no children
        ?assertEqual([], dynamic_supervisor:which_children(Sup)),
        
        %% Start a child
        {ok, _Pid} = dynamic_supervisor:start_child(Sup,
            #{id => test_worker,
              start => {test_worker, start_link, []},
              type => worker,
              modules => [test_worker]}),
        
        %% Check children list
        Children = dynamic_supervisor:which_children(Sup),
        ?assertEqual(1, length(Children)),
        [{undefined, Pid, Type, Modules}] = Children,
        ?assert(is_pid(Pid)),
        ?assertEqual(worker, Type),
        ?assertEqual([test_worker], Modules)
    end.

test_count_children(Sup) ->
    fun() ->
        %% Initially no children
        Counts1 = dynamic_supervisor:count_children(Sup),
        ?assertEqual(0, maps:get(specs, Counts1)),
        ?assertEqual(0, maps:get(active, Counts1)),
        ?assertEqual(0, maps:get(workers, Counts1)),
        ?assertEqual(0, maps:get(supervisors, Counts1)),
        
        %% Start a worker
        {ok, _} = dynamic_supervisor:start_child(Sup,
            #{id => worker1,
              start => {test_worker, start_link, []},
              type => worker}),
        
        %% Start a supervisor
        {ok, _} = dynamic_supervisor:start_child(Sup,
            #{id => sup1,
              start => {test_supervisor, start_link, []},
              type => supervisor}),
        
        %% Check counts
        Counts2 = dynamic_supervisor:count_children(Sup),
        ?assertEqual(2, maps:get(specs, Counts2)),
        ?assertEqual(2, maps:get(active, Counts2)),
        ?assertEqual(1, maps:get(workers, Counts2)),
        ?assertEqual(1, maps:get(supervisors, Counts2))
    end.

test_max_children(Sup) ->
    fun() ->
        %% Create a supervisor with max_children limit
        {ok, LimitedSup} = dynamic_supervisor:start_link([
            {strategy, one_for_one},
            {max_children, 2}
        ]),
        
        try
            %% Start children up to limit
            {ok, _} = dynamic_supervisor:start_child(LimitedSup,
                #{id => worker1, start => {test_worker, start_link, []}}),
            {ok, _} = dynamic_supervisor:start_child(LimitedSup,
                #{id => worker2, start => {test_worker, start_link, []}}),
            
            %% Try to exceed limit
            {error, max_children} = dynamic_supervisor:start_child(LimitedSup,
                #{id => worker3, start => {test_worker, start_link, []}})
        after
            dynamic_supervisor:stop(LimitedSup)
        end
    end.

test_restart_permanent(Sup) ->
    fun() ->
        %% Start a permanent child
        {ok, Pid} = dynamic_supervisor:start_child(Sup,
            #{id => perm_worker,
              start => {test_worker, start_link, []},
              restart => permanent}),
        
        %% Kill it
        exit(Pid, kill),
        timer:sleep(100),
        
        %% Should be restarted
        Children = dynamic_supervisor:which_children(Sup),
        ?assertEqual(1, length(Children))
    end.

test_restart_temporary(Sup) ->
    fun() ->
        %% Start a temporary child
        {ok, Pid} = dynamic_supervisor:start_child(Sup,
            #{id => temp_worker,
              start => {test_worker, start_link, []},
              restart => temporary}),
        
        %% Kill it
        exit(Pid, kill),
        timer:sleep(100),
        
        %% Should not be restarted
        Children = dynamic_supervisor:which_children(Sup),
        ?assertEqual(0, length(Children))
    end.

test_restart_transient(Sup) ->
    fun() ->
        %% Start a transient child
        {ok, Pid} = dynamic_supervisor:start_child(Sup,
            #{id => trans_worker,
              start => {test_worker, start_link, []},
              restart => transient}),
        
        %% Normal exit - should not restart
        Pid ! {stop, normal},
        timer:sleep(100),
        
        Children1 = dynamic_supervisor:which_children(Sup),
        ?assertEqual(0, length(Children1)),
        
        %% Start another transient child
        {ok, Pid2} = dynamic_supervisor:start_child(Sup,
            #{id => trans_worker2,
              start => {test_worker, start_link, []},
              restart => transient}),
        
        %% Abnormal exit - should restart
        exit(Pid2, kill),
        timer:sleep(100),
        
        Children2 = dynamic_supervisor:which_children(Sup),
        ?assertEqual(1, length(Children2))
    end.

