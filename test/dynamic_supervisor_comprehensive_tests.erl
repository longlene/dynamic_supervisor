-module(dynamic_supervisor_comprehensive_tests).

-include_lib("eunit/include/eunit.hrl").

%% Test fixtures and helpers
-export([start_link/1, start_link/2, init/1]).

%%====================================================================
%% Helper functions
%%====================================================================

%% start_link/1 clauses
start_link(ok3) -> 
    {ok, spawn_link(fun() -> timer:sleep(60000) end), extra};
start_link(ok2) -> 
    {ok, spawn_link(fun() -> timer:sleep(60000) end)};
start_link(error) -> 
    {error, found};
start_link(ignore) -> 
    ignore;
start_link(unknown) -> 
    unknown.

%% start_link/2 clauses  
start_link(restart, Value) ->
    case get({restart, Value}) of
        true ->
            start_link(Value);
        _ ->
            put({restart, Value}, true),
            start_link(ok2)
    end;
start_link(non_local, throw) -> 
    throw(oops);
start_link(non_local, error) -> 
    error(oops);
start_link(non_local, exit) -> 
    exit(oops);
start_link(try_again, Notify) ->
    case get(try_again) of
        true ->
            put(try_again, false),
            Notify ! {try_again, false},
            {error, try_again};
        _ ->
            put(try_again, true),
            Notify ! {try_again, true},
            start_link(ok2)
    end.

sleepy_worker() ->
    sleepy_worker([]).

sleepy_worker(Opts) ->
    BaseSpec = #{id => sleepy_task, start => {sleepy_proc, start_link, []}},
    maps:merge(BaseSpec, maps:from_list(Opts)).

current_module_worker(Args) ->
    current_module_worker(Args, []).

current_module_worker(Args, Opts) ->
    BaseSpec = #{id => ?MODULE, start => {?MODULE, start_link, Args}},
    maps:merge(BaseSpec, maps:from_list(Opts)).

assert_kill(Pid, Reason) ->
    Ref = monitor(process, Pid),
    exit(Pid, Reason),
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    after 5000 ->
        error(timeout_waiting_for_death)
    end.

%%====================================================================
%% Test groups
%%====================================================================

dynamic_supervisor_comprehensive_test_() ->
    {foreach,
     fun() -> ok end,
     fun(_) -> ok end,
     [
      {"Basic functionality", fun test_basic_functionality/0},
      {"Module-based supervisor", fun test_module_based_supervisor/0},
      {"Init supervisor options", fun test_init_supervisor_options/0},
      {"Start link with invalid options", fun test_start_link_invalid_options/0},
      {"Start child with old spec", fun test_start_child_old_spec/0},
      {"Start child with new spec", fun test_start_child_new_spec/0},
      {"Start child with extra arguments", fun test_start_child_extra_arguments/0},
      {"Start child with invalid spec", fun test_start_child_invalid_spec/0},
      {"Start child different returns", fun test_start_child_different_returns/0},
      {"Start child with throw/error/exit", fun test_start_child_throw_error_exit/0},
      {"Start child with max_children", fun test_start_child_max_children/0},
      {"Temporary child restart", fun test_temporary_child_restart/0},
      {"Transient child restart", fun test_transient_child_restart/0},
      {"Permanent child restart", fun test_permanent_child_restart/0},
      {"Child restarted with different values", fun test_child_restarted_different_values/0},
      {"Restarting children counted in max_children", fun test_restarting_children_max_count/0},
      {"Child triggers maximum restarts", fun test_child_triggers_max_restarts/0},
      {"Terminate child tests", fun test_terminate_child/0},
      {"Termination with different shutdown values", fun test_termination_shutdown/0}
     ]}.

%%====================================================================
%% Test cases
%%====================================================================

test_basic_functionality() ->
    %% Can be supervised directly - using new Erlang-style API
    {ok, DynSup} = dynamic_supervisor:start_link({local, dyn_sup_spec_test}, []),
    timer:sleep(100),  % Give time for registration
    ?assertEqual([], dynamic_supervisor:which_children(DynSup)),
    ?assertMatch(#{specs := 0, active := 0}, dynamic_supervisor:count_children(DynSup)),
    dynamic_supervisor:stop(DynSup).

test_module_based_supervisor() ->
    %% Test with name registration
    {ok, Pid} = dynamic_supervisor:start_link(simple_supervisor, {ok, #{}}, [{name, {local, test_mod_sup}}]),
    ?assert(is_pid(Pid)),
    timer:sleep(100),  % Give time for registration
    ?assert(is_process_alive(Pid)),
    ?assertEqual(ok, dynamic_supervisor:stop(Pid)).

test_init_supervisor_options() ->
    %% Test default options
    Expected = #{strategy => one_for_one,
                 intensity => 3,
                 period => 5,
                 max_children => infinity,
                 extra_arguments => []},
    ?assertEqual({ok, Expected}, dynamic_supervisor:init([])).

test_start_link_invalid_options() ->
    process_flag(trap_exit, true),
    
    %% Invalid strategy
    ?assertMatch({error, {supervisor_data, {invalid_strategy, unknown}}},
                 dynamic_supervisor:start_link(simple_supervisor, {ok, #{strategy => unknown}}, [])),
    
    %% Invalid intensity
    ?assertMatch({error, {supervisor_data, {invalid_intensity, -1}}},
                 dynamic_supervisor:start_link(simple_supervisor, {ok, #{intensity => -1}}, [])),
    
    %% Invalid period
    ?assertMatch({error, {supervisor_data, {invalid_period, 0}}},
                 dynamic_supervisor:start_link(simple_supervisor, {ok, #{period => 0}}, [])),
    
    %% Invalid max_children
    ?assertMatch({error, {supervisor_data, {invalid_max_children, -1}}},
                 dynamic_supervisor:start_link(simple_supervisor, {ok, #{max_children => -1}}, [])),
    
    %% Invalid extra_arguments
    ?assertMatch({error, {supervisor_data, {invalid_extra_arguments, -1}}},
                 dynamic_supervisor:start_link(simple_supervisor, {ok, #{extra_arguments => -1}}, [])),
    
    %% Bad return
    ?assertMatch({error, {bad_return, {simple_supervisor, init, unknown}}},
                 dynamic_supervisor:start_link(simple_supervisor, unknown, [])),
    
    %% Ignore
    ?assertEqual(ignore, dynamic_supervisor:start_link(simple_supervisor, ignore, [])).

test_start_child_old_spec() ->
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}]),
    Child = {timer_task, {sleepy_proc, start_link, []}, temporary, 5000, worker, [sleepy_proc]},
    {ok, ChildPid} = dynamic_supervisor:start_child(Pid, Child),
    ?assert(is_pid(ChildPid)),
    dynamic_supervisor:stop(Pid).

test_start_child_new_spec() ->
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}]),
    Child = #{id => timer_task,
              restart => temporary,
              start => {sleepy_proc, start_link, []}},
    {ok, ChildPid} = dynamic_supervisor:start_child(Pid, Child),
    ?assert(is_pid(ChildPid)),
    dynamic_supervisor:stop(Pid).

test_start_child_extra_arguments() ->
    Parent = self(),
    
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}, {extra_arguments, [Parent]}]),
    Child = #{id => task,
              restart => temporary,
              start => {notify_proc, start_link, []}},
    {ok, ChildPid} = dynamic_supervisor:start_child(Pid, Child),
    ?assert(is_pid(ChildPid)),
    receive from_child -> ok after 1000 -> ?assert(false) end,
    dynamic_supervisor:stop(Pid).

test_start_child_invalid_spec() ->
    ?assertEqual({error, {invalid_child_spec, #{}}}, 
                 dynamic_supervisor:start_child(not_used, #{})),
    
    ?assertEqual({error, {invalid_mfa, 2}},
                 dynamic_supervisor:start_child(not_used, {1, 2, 3, 4, 5, 6})),
    
    ?assertEqual({error, {invalid_mfa, {timer, foo, bar}}},
                 dynamic_supervisor:start_child(not_used, 
                     #{id => 1, start => {timer, foo, bar}})),
    
    ?assertEqual({error, {invalid_shutdown, -1}},
                 dynamic_supervisor:start_child(not_used,
                     #{id => 1, start => {timer, sleep, [100]}, shutdown => -1})),
    
    ?assertEqual({error, {invalid_significant, true}},
                 dynamic_supervisor:start_child(not_used,
                     #{id => 1, start => {timer, sleep, [100]}, significant => true})).

test_start_child_different_returns() ->
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}]),
    
    ?assertMatch({ok, _, extra}, 
                 dynamic_supervisor:start_child(Pid, current_module_worker([ok3]))),
    ?assertMatch({ok, _}, 
                 dynamic_supervisor:start_child(Pid, current_module_worker([ok2]))),
    ?assertEqual(ignore, 
                 dynamic_supervisor:start_child(Pid, current_module_worker([ignore]))),
    ?assertEqual({error, found},
                 dynamic_supervisor:start_child(Pid, current_module_worker([error]))),
    ?assertEqual({error, unknown},
                 dynamic_supervisor:start_child(Pid, current_module_worker([unknown]))),
    
    dynamic_supervisor:stop(Pid).

test_start_child_throw_error_exit() ->
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}]),
    
    ?assertMatch({error, {{nocatch, oops}, _}},
                 dynamic_supervisor:start_child(Pid, current_module_worker([non_local, throw]))),
    
    ?assertMatch({error, {oops, _}},
                 dynamic_supervisor:start_child(Pid, current_module_worker([non_local, error]))),
    
    ?assertEqual({error, oops},
                 dynamic_supervisor:start_child(Pid, current_module_worker([non_local, exit]))),
    
    dynamic_supervisor:stop(Pid).

test_start_child_max_children() ->
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}, {max_children, 0}]),
    
    ?assertEqual({error, max_children},
                 dynamic_supervisor:start_child(Pid, current_module_worker([ok2]))),
                 
    dynamic_supervisor:stop(Pid).

test_temporary_child_restart() ->
    Child = maps:put(restart, temporary, current_module_worker([ok2])),
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}]),
    
    {ok, ChildPid} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid, shutdown),
    ?assertMatch(#{workers := 0, active := 0}, dynamic_supervisor:count_children(Pid)),
    
    {ok, ChildPid2} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid2, whatever),
    ?assertMatch(#{workers := 0, active := 0}, dynamic_supervisor:count_children(Pid)),
    
    dynamic_supervisor:stop(Pid).

test_transient_child_restart() ->
    Child = maps:put(restart, transient, current_module_worker([ok2])),
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}]),
    
    %% Normal shutdown - should not restart
    {ok, ChildPid} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid, shutdown),
    timer:sleep(100),
    ?assertMatch(#{workers := 0, active := 0}, dynamic_supervisor:count_children(Pid)),
    
    %% Shutdown with reason - should not restart
    {ok, ChildPid2} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid2, {shutdown, signal}),
    timer:sleep(100),
    ?assertMatch(#{workers := 0, active := 0}, dynamic_supervisor:count_children(Pid)),
    
    %% Abnormal exit - should restart
    {ok, ChildPid3} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid3, whatever),
    timer:sleep(100),
    ?assertMatch(#{workers := 1, active := 1}, dynamic_supervisor:count_children(Pid)),
    
    dynamic_supervisor:stop(Pid).

test_permanent_child_restart() ->
    Child = maps:put(restart, permanent, current_module_worker([ok2])),
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}, {max_restarts, 100000}]),
    
    %% All exits should restart
    {ok, ChildPid} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid, shutdown),
    timer:sleep(100),
    ?assertMatch(#{workers := 1, active := 1}, dynamic_supervisor:count_children(Pid)),
    
    {ok, ChildPid2} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid2, {shutdown, signal}),
    timer:sleep(100),
    ?assertMatch(#{workers := 2, active := 2}, dynamic_supervisor:count_children(Pid)),
    
    {ok, ChildPid3} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid3, whatever),
    timer:sleep(100),
    ?assertMatch(#{workers := 3, active := 3}, dynamic_supervisor:count_children(Pid)),
    
    dynamic_supervisor:stop(Pid).

test_child_restarted_different_values() ->
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}, {max_restarts, 100000}]),
    
    {ok, Child1} = dynamic_supervisor:start_child(Pid, current_module_worker([restart, ok2])),
    ?assertMatch([{undefined, Child1, worker, [?MODULE]}], 
                 dynamic_supervisor:which_children(Pid)),
    
    assert_kill(Child1, shutdown),
    timer:sleep(100),
    ?assertMatch(#{workers := 1, active := 1}, dynamic_supervisor:count_children(Pid)),
    
    dynamic_supervisor:stop(Pid).

test_restarting_children_max_count() ->
    Child = maps:put(restart, permanent, current_module_worker([restart, error])),
    Opts = [{strategy, one_for_one}, {max_children, 1}, {max_restarts, 100000}],
    {ok, Pid} = dynamic_supervisor:start_link(Opts),
    
    {ok, ChildPid} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid, shutdown),
    timer:sleep(100),
    ?assertMatch(#{workers := 1, active := 0}, dynamic_supervisor:count_children(Pid)),
    
    Child2 = maps:put(restart, permanent, current_module_worker([restart, ok2])),
    ?assertEqual({error, max_children}, dynamic_supervisor:start_child(Pid, Child2)),
    
    dynamic_supervisor:stop(Pid).

test_child_triggers_max_restarts() ->
    process_flag(trap_exit, true),
    Child = maps:put(restart, permanent, current_module_worker([restart, error])),
    {ok, Pid} = dynamic_supervisor:start_link([{strategy, one_for_one}, {max_restarts, 1}]),
    
    {ok, ChildPid} = dynamic_supervisor:start_child(Pid, Child),
    assert_kill(ChildPid, shutdown),
    receive
        {'EXIT', Pid, shutdown} -> ok
    after 5000 ->
        ?assert(false)
    end.

test_terminate_child() ->
    {ok, Sup} = dynamic_supervisor:start_link([{strategy, one_for_one}]),
    
    %% Test with brutal_kill
    Child = maps:put(shutdown, brutal_kill, sleepy_worker()),
    {ok, ChildPid} = dynamic_supervisor:start_child(Sup, Child),
    
    Ref = monitor(process, ChildPid),
    ?assertEqual(ok, dynamic_supervisor:terminate_child(Sup, ChildPid)),
    receive
        {'DOWN', Ref, process, ChildPid, killed} -> ok
    after 5000 ->
        ?assert(false)
    end,
    
    ?assertEqual({error, not_found}, dynamic_supervisor:terminate_child(Sup, ChildPid)),
    ?assertMatch(#{workers := 0, active := 0}, dynamic_supervisor:count_children(Sup)),
    
    dynamic_supervisor:stop(Sup).

test_termination_shutdown() ->
    process_flag(trap_exit, true),
    {ok, Sup} = dynamic_supervisor:start_link([{strategy, one_for_one}]),
    
    %% Test brutal_kill
    Child1 = maps:put(shutdown, brutal_kill, sleepy_worker()),
    {ok, Child1Pid} = dynamic_supervisor:start_child(Sup, Child1),
    
    %% Test infinity shutdown
    Child2 = maps:put(shutdown, infinity, sleepy_worker()),
    {ok, Child2Pid} = dynamic_supervisor:start_child(Sup, Child2),
    
    %% Test integer shutdown
    Child3 = maps:put(shutdown, 1000, sleepy_worker()),
    {ok, Child3Pid} = dynamic_supervisor:start_child(Sup, Child3),
    
    Ref1 = monitor(process, Child1Pid),
    Ref2 = monitor(process, Child2Pid),
    Ref3 = monitor(process, Child3Pid),
    
    assert_kill(Sup, shutdown),
    
    receive {'DOWN', Ref1, process, Child1Pid, killed} -> ok after 5000 -> ?assert(false) end,
    receive {'DOWN', Ref2, process, Child2Pid, shutdown} -> ok after 5000 -> ?assert(false) end,
    receive {'DOWN', Ref3, process, Child3Pid, shutdown} -> ok after 5000 -> ?assert(false) end.

%% Supervisor callback for testing
init({Strategy, Children}) ->
    {ok, {{Strategy, 5, 10}, Children}}.

