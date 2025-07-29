%%% @doc
%%% A supervisor optimized to only start children dynamically.
%%%
%%% The standard supervisor module was designed to handle mostly static children
%%% that are started in the given order when the supervisor starts. A
%%% dynamic_supervisor starts with no children. Instead, children are
%%% started on demand via start_child/2 and there is no ordering between
%%% children. This allows the dynamic_supervisor to hold millions of
%%% children by using efficient data structures and to execute certain
%%% operations, such as shutting down, concurrently.
%%%
%%% == Examples ==
%%%
%%% A dynamic supervisor is started with no children and often a name:
%%%
%%% ```
%%% {ok, Pid} = dynamic_supervisor:start_link([
%%%     {name, {local, my_dynamic_supervisor}},
%%%     {strategy, one_for_one}
%%% ]).
%%% '''
%%%
%%% Once the dynamic supervisor is running, we can use it to start children
%%% on demand. Given this sample gen_server:
%%%
%%% ```
%%% -module(counter).
%%% -behaviour(gen_server).
%%% 
%%% -export([start_link/1, inc/1]).
%%% -export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%%% 
%%% start_link(Initial) ->
%%%     gen_server:start_link(?MODULE, Initial, []).
%%% 
%%% inc(Pid) ->
%%%     gen_server:call(Pid, inc).
%%% 
%%% init(Initial) ->
%%%     {ok, Initial}.
%%% 
%%% handle_call(inc, _From, Count) ->
%%%     {reply, Count, Count + 1}.
%%% '''
%%%
%%% We can use start_child/2 with a child specification to start a counter
%%% server:
%%%
%%% ```
%%% {ok, Counter1} = dynamic_supervisor:start_child(my_dynamic_supervisor, 
%%%     #{id => counter1,
%%%       start => {counter, start_link, [0]},
%%%       restart => permanent,
%%%       shutdown => 5000,
%%%       type => worker,
%%%       modules => [counter]}).
%%% counter:inc(Counter1).
%%% %% 0
%%% 
%%% {ok, Counter2} = dynamic_supervisor:start_child(my_dynamic_supervisor,
%%%     #{id => counter2,
%%%       start => {counter, start_link, [10]},
%%%       restart => permanent,
%%%       shutdown => 5000,
%%%       type => worker,
%%%       modules => [counter]}).
%%% counter:inc(Counter2).
%%% %% 10
%%% 
%%% dynamic_supervisor:count_children(my_dynamic_supervisor).
%%% %% #{active => 2, specs => 2, supervisors => 0, workers => 2}
%%% '''
%%%
%%% @end
-module(dynamic_supervisor).

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/3]).
-export([start_child/2, terminate_child/2]).
-export([which_children/1, count_children/1]).
-export([stop/1, stop/2, stop/3]).
-export([init_supervisor/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Types
-type strategy() :: one_for_one.
-type restart() :: permanent | transient | temporary.
-type shutdown() :: brutal_kill | infinity | non_neg_integer().
-type child_type() :: worker | supervisor.
-type modules() :: [module()] | dynamic.
-type child_spec() :: #{id := term(),
                        start := {module(), atom(), [term()]},
                        restart => restart(),
                        shutdown => shutdown(),
                        type => child_type(),
                        modules => modules(),
                        significant => boolean()}.
-type sup_flags() :: #{strategy := strategy(),
                       intensity => non_neg_integer(),
                       period => pos_integer(),
                       max_children => non_neg_integer() | infinity,
                       extra_arguments => [term()],
                       auto_shutdown => never}.
-type init_option() :: {strategy, strategy()} |
                       {max_restarts, non_neg_integer()} |
                       {max_seconds, pos_integer()} |
                       {max_children, non_neg_integer() | infinity} |
                       {extra_arguments, [term()]}.
-type start_option() :: {name, atom() | {local, atom()} | {global, atom()} | {via, module(), term()}} |
                        {timeout, timeout()} |
                        {debug, [sys:debug_option()]} |
                        {spawn_opt, [term()]}.

%% Internal state
-record(state, {
    name :: {pid(), module()} | {local, atom()} | {global, atom()} | {via, module(), term()},
    mod :: module(),
    args :: term(),
    strategy :: strategy(),
    max_children :: non_neg_integer() | infinity,
    max_restarts :: non_neg_integer(),
    max_seconds :: pos_integer(),
    extra_arguments :: [term()],
    children = #{} :: #{pid() => {Child :: tuple(), restart(), shutdown(), child_type(), modules()}},
    restarts = [] :: [integer()]
}).

%% Behaviour callback
-callback init(Args :: term()) ->
    {ok, sup_flags()} | ignore.

%%====================================================================
%% API functions
%%====================================================================

%% @doc Starts a supervisor with the given options.
%%
%% This function is typically not invoked directly, instead it is invoked
%% when using a dynamic_supervisor as a child of another supervisor.
%%
%% If the supervisor is successfully spawned, this function returns
%% `{ok, Pid}', where `Pid' is the PID of the supervisor. If the supervisor
%% is given a name and a process with the specified name already exists,
%% the function returns `{error, {already_started, Pid}}', where `Pid'
%% is the PID of that process.
%%
%% Options:
%% <ul>
%% <li>`{name, Name}' - registers the supervisor under the given name.</li>
%% <li>`{strategy, Strategy}' - the restart strategy option. The only supported
%%     value is `one_for_one' which means that no other child is
%%     terminated if a child process terminates.</li>
%% <li>`{max_restarts, MaxRestarts}' - the maximum number of restarts allowed in
%%     a time frame. Defaults to `3'.</li>
%% <li>`{max_seconds, MaxSeconds}' - the time frame in which `max_restarts' applies.
%%     Defaults to `5'.</li>
%% <li>`{max_children, MaxChildren}' - the maximum amount of children to be running
%%     under this supervisor at the same time. When `max_children' is
%%     exceeded, `start_child/2' returns `{error, max_children}'. Defaults
%%     to `infinity'.</li>
%% <li>`{extra_arguments, ExtraArgs}' - arguments that are prepended to the arguments
%%     specified in the child spec given to `start_child/2'. Defaults to
%%     an empty list.</li>
%% </ul>
%% @end
-spec start_link([init_option() | start_option()]) -> {ok, pid()} | ignore | {error, term()}.
start_link(Options) when is_list(Options) ->
    Keys = [extra_arguments, max_children, max_seconds, max_restarts, strategy],
    {SupOpts, StartOpts} = lists:partition(fun({K, _}) -> lists:member(K, Keys) end, Options),
    start_link(dynamic_supervisor_default, init_supervisor(SupOpts), StartOpts).

%% @doc Starts a module-based supervisor process with the given `Module' and `InitArg'.
%%
%% To start the supervisor, the `init/1' callback will be invoked in the given
%% `Module', with `InitArg' as its argument. The `init/1' callback must return a
%% supervisor specification which can be created with the help of the `init/1'
%% function.
%% @end
-spec start_link(module(), term(), [start_option()]) -> {ok, pid()} | ignore | {error, term()}.
start_link(Module, InitArg, Opts) ->
    gen_server:start_link(?MODULE, {Module, InitArg, proplists:get_value(name, Opts)}, Opts).

%% @doc Dynamically adds a child specification to `Supervisor' and starts that child.
%%
%% `ChildSpec' should be a valid child specification.
%% The child process will be started as defined in the child specification.
%%
%% If the child process start function returns `{ok, Child}' or `{ok, Child, Info}',
%% then child specification and PID are added to the supervisor and
%% this function returns the same value.
%%
%% If the child process start function returns `ignore', then no child is added
%% to the supervision tree and this function returns `ignore' too.
%%
%% If the child process start function returns an error tuple or an erroneous
%% value, or if it fails, the child specification is discarded and this function
%% returns `{error, Error}' where `Error' is the error or erroneous value
%% returned from child process start function, or failure reason if it fails.
%%
%% If the supervisor already has N children in a way that N exceeds the amount
%% of `max_children' set on the supervisor initialization, then
%% this function returns `{error, max_children}'.
%% @end
-spec start_child(Supervisor :: pid() | atom() | {atom(), node()} | {global, atom()} | {via, module(), term()},
                  ChildSpec :: child_spec() | {module(), term()} | module()) ->
    {ok, pid()} | {ok, pid(), term()} | ignore | {error, term()}.
start_child(Supervisor, ChildSpec) when is_map(ChildSpec) ->
    case validate_child_spec(ChildSpec) of
        {ok, Child} -> call(Supervisor, {start_child, Child});
        {error, Error} -> {error, Error}
    end;
start_child(Supervisor, ChildSpec) when is_tuple(ChildSpec), tuple_size(ChildSpec) =:= 6 ->
    %% Old-style child spec
    case validate_child_spec(ChildSpec) of
        {ok, Child} -> call(Supervisor, {start_child, Child});
        {error, Error} -> {error, Error}
    end;
start_child(Supervisor, Module) when is_atom(Module) ->
    start_child(Supervisor, #{id => Module, start => {Module, start_link, []}});
start_child(Supervisor, {Module, Args}) when is_atom(Module) ->
    start_child(Supervisor, #{id => Module, start => {Module, start_link, [Args]}}).

%% @doc Terminates the given child identified by `Pid'.
%%
%% If successful, this function returns `ok'. If there is no process with
%% the given PID, this function returns `{error, not_found}'.
%% @end
-spec terminate_child(Supervisor :: pid() | atom() | {atom(), node()} | {global, atom()} | {via, module(), term()},
                      Pid :: pid()) -> ok | {error, not_found}.
terminate_child(Supervisor, Pid) when is_pid(Pid) ->
    call(Supervisor, {terminate_child, Pid}).

%% @doc Returns a list with information about all children.
%%
%% Note that calling this function when supervising a large number
%% of children under low memory conditions can cause an out of memory
%% exception.
%%
%% This function returns a list of tuples containing:
%% <ul>
%% <li>`Id' - it is always `undefined' for dynamic supervisors</li>
%% <li>`Child' - the PID of the corresponding child process or the
%%     atom `restarting' if the process is about to be restarted</li>
%% <li>`Type' - `worker' or `supervisor' as defined in the child
%%     specification</li>
%% <li>`Modules' - as defined in the child specification</li>
%% </ul>
%% @end
-spec which_children(Supervisor :: pid() | atom() | {atom(), node()} | {global, atom()} | {via, module(), term()}) ->
    [{undefined, pid() | restarting, worker | supervisor, [module()] | dynamic}].
which_children(Supervisor) ->
    call(Supervisor, which_children).

%% @doc Returns a map containing count values for the supervisor.
%%
%% The map contains the following keys:
%% <ul>
%% <li>`specs' - the number of children processes</li>
%% <li>`active' - the count of all actively running child processes managed by
%%     this supervisor</li>
%% <li>`supervisors' - the count of all supervisors whether or not the child
%%     process is still alive</li>
%% <li>`workers' - the count of all workers, whether or not the child process
%%     is still alive</li>
%% </ul>
%% @end
-spec count_children(Supervisor :: pid() | atom() | {atom(), node()} | {global, atom()} | {via, module(), term()}) ->
    #{specs := non_neg_integer(),
      active := non_neg_integer(),
      supervisors := non_neg_integer(),
      workers := non_neg_integer()}.
count_children(Supervisor) ->
    Proplist = call(Supervisor, count_children),
    maps:from_list(Proplist).

%% @doc Synchronously stops the given supervisor with the given `Reason'.
%%
%% It returns `ok' if the supervisor terminates with the given
%% reason. If it terminates with another reason, the call exits.
%%
%% This function keeps OTP semantics regarding error reporting.
%% If the reason is any other than `normal', `shutdown' or
%% `{shutdown, _}', an error report is logged.
%% @end
-spec stop(Supervisor :: pid() | atom() | {atom(), node()} | {global, atom()} | {via, module(), term()}) -> ok.
stop(Supervisor) ->
    stop(Supervisor, normal, infinity).

-spec stop(Supervisor :: pid() | atom() | {atom(), node()} | {global, atom()} | {via, module(), term()},
           Reason :: term()) -> ok.
stop(Supervisor, Reason) ->
    stop(Supervisor, Reason, infinity).

-spec stop(Supervisor :: pid() | atom() | {atom(), node()} | {global, atom()} | {via, module(), term()},
           Reason :: term(),
           Timeout :: timeout()) -> ok.
stop(Supervisor, Reason, Timeout) ->
    gen_server:stop(Supervisor, Reason, Timeout).

%% @doc Receives a set of `Options' that initializes a dynamic supervisor.
%%
%% This is typically invoked at the end of the `init/1' callback of
%% module-based supervisors.
%%
%% It accepts the same `Options' as `start_link/1' (except for `name')
%% and it returns a tuple containing the supervisor options.
%%
%% Example:
%% ```
%% init(_Arg) ->
%%     dynamic_supervisor:init_supervisor([{max_children, 1000}]).
%% '''
%% @end
-spec init_supervisor([init_option()]) -> {ok, sup_flags()}.
init_supervisor(Options) when is_list(Options) ->
    Strategy = proplists:get_value(strategy, Options, one_for_one),
    Intensity = proplists:get_value(max_restarts, Options, 3),
    Period = proplists:get_value(max_seconds, Options, 5),
    MaxChildren = proplists:get_value(max_children, Options, infinity),
    ExtraArguments = proplists:get_value(extra_arguments, Options, []),
    
    Flags = #{
        strategy => Strategy,
        intensity => Intensity,
        period => Period,
        max_children => MaxChildren,
        extra_arguments => ExtraArguments
    },
    
    {ok, Flags}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init({Mod, InitArg, Name}) ->
    process_flag(trap_exit, true),
    case Mod:init(InitArg) of
        {ok, Flags} when is_map(Flags) ->
            NameSpec = case Name of
                undefined -> {self(), Mod};
                N when is_atom(N) -> {local, N};
                N when is_tuple(N) -> N
            end,
            
            State = #state{mod = Mod, args = InitArg, name = NameSpec},
            
            case init_state(State, Flags) of
                {ok, NewState} -> {ok, NewState};
                {error, Reason} -> {stop, {supervisor_data, Reason}}
            end;
        
        ignore ->
            ignore;
        
        Other ->
            {stop, {bad_return, {Mod, init, Other}}}
    end.

%% @private
handle_call(which_children, _From, #state{children = Children} = State) ->
    Reply = [
        {undefined, 
         case Child of
             {restarting, {_, _, _, Type, Modules}} -> restarting;
             _ -> Pid
         end,
         case Child of
             {restarting, {_, _, _, Type, _}} -> Type;
             {_, _, _, Type, _} -> Type
         end,
         case Child of
             {restarting, {_, _, _, _, Modules}} -> Modules;
             {_, _, _, _, Modules} -> Modules
         end}
        || {Pid, Child} <- maps:to_list(Children)
    ],
    {reply, Reply, State};

handle_call(count_children, _From, #state{children = Children} = State) ->
    Specs = maps:size(Children),
    {Active, Workers, Supervisors} = count_children_stats(Children),
    Reply = [{specs, Specs}, {active, Active}, {supervisors, Supervisors}, {workers, Workers}],
    {reply, Reply, State};

handle_call({terminate_child, Pid}, _From, #state{children = Children} = State) ->
    case maps:find(Pid, Children) of
        {ok, Child} ->
            ok = terminate_children(#{Pid => Child}, State),
            {reply, ok, State#state{children = maps:remove(Pid, Children)}};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({start_child, Child}, _From, #state{children = Children, max_children = MaxChildren} = State) ->
    case maps:size(Children) < MaxChildren of
        true ->
            handle_start_child(Child, State);
        false ->
            {reply, {error, max_children}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, not_implemented}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({'EXIT', Pid, Reason}, State) ->
    case maybe_restart_child(Pid, Reason, State) of
        {ok, NewState} -> {noreply, NewState};
        {shutdown, NewState} -> {stop, shutdown, NewState}
    end;

handle_info({'$gen_restart', Pid}, #state{children = Children} = State) ->
    case maps:find(Pid, Children) of
        {ok, {restarting, Child}} ->
            case restart_child(Pid, Child, State) of
                {ok, NewState} -> {noreply, NewState};
                {shutdown, NewState} -> {stop, shutdown, NewState}
            end;
        _ ->
            {noreply, State}
    end;

handle_info(_Info, State) ->
    error_logger:error_msg("Dynamic supervisor received unexpected message: ~p~n", [_Info]),
    {noreply, State}.

%% @private
terminate(_Reason, #state{children = Children} = State) ->
    ok = terminate_children(Children, State).

%% @private
code_change(_OldVsn, #state{mod = Mod, args = InitArg} = State, _Extra) ->
    case Mod:init(InitArg) of
        {ok, Flags} when is_map(Flags) ->
            case init_state(State, Flags) of
                {ok, NewState} -> {ok, NewState};
                {error, Reason} -> {error, {supervisor_data, Reason}}
            end;
        ignore ->
            {ok, State};
        Error ->
            Error
    end.

%%====================================================================
%% Internal functions
%%====================================================================


init_state(State, Flags) ->
    ExtraArguments = maps:get(extra_arguments, Flags, []),
    MaxChildren = maps:get(max_children, Flags, infinity),
    MaxRestarts = maps:get(intensity, Flags, 1),
    MaxSeconds = maps:get(period, Flags, 5),
    Strategy = maps:get(strategy, Flags, one_for_one),
    
    case validate_strategy(Strategy) of
        ok ->
            case validate_restarts(MaxRestarts) of
                ok ->
                    case validate_seconds(MaxSeconds) of
                        ok ->
                            case validate_max_children(MaxChildren) of
                                ok ->
                                    case validate_extra_arguments(ExtraArguments) of
                                        ok ->
                                            {ok, State#state{
                                                extra_arguments = ExtraArguments,
                                                max_children = MaxChildren,
                                                max_restarts = MaxRestarts,
                                                max_seconds = MaxSeconds,
                                                strategy = Strategy
                                            }};
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_strategy(one_for_one) -> ok;
validate_strategy(Strategy) -> {error, {invalid_strategy, Strategy}}.

validate_restarts(Restarts) when is_integer(Restarts), Restarts >= 0 -> ok;
validate_restarts(Restarts) -> {error, {invalid_intensity, Restarts}}.

validate_seconds(Seconds) when is_integer(Seconds), Seconds > 0 -> ok;
validate_seconds(Seconds) -> {error, {invalid_period, Seconds}}.

validate_max_children(infinity) -> ok;
validate_max_children(Max) when is_integer(Max), Max >= 0 -> ok;
validate_max_children(Max) -> {error, {invalid_max_children, Max}}.

validate_extra_arguments(Args) when is_list(Args) -> ok;
validate_extra_arguments(Args) -> {error, {invalid_extra_arguments, Args}}.

validate_child_spec(#{id := _Id, start := Start} = ChildSpec) ->
    Restart = maps:get(restart, ChildSpec, permanent),
    Type = maps:get(type, ChildSpec, worker),
    Modules = maps:get(modules, ChildSpec, [element(1, Start)]),
    Shutdown = case Type of
        worker -> maps:get(shutdown, ChildSpec, 5000);
        supervisor -> maps:get(shutdown, ChildSpec, infinity)
    end,
    Significant = maps:get(significant, ChildSpec, false),
    
    validate_child(Start, Restart, Shutdown, Type, Modules, Significant);

validate_child_spec({_Id, Start, Restart, Shutdown, Type, Modules}) ->
    validate_child(Start, Restart, Shutdown, Type, Modules, false);

validate_child_spec(Other) ->
    {error, {invalid_child_spec, Other}}.

validate_child(Start, Restart, Shutdown, Type, Modules, Significant) ->
    case validate_start(Start) of
        ok ->
            case validate_restart(Restart) of
                ok ->
                    case validate_shutdown(Shutdown) of
                        ok ->
                            case validate_type(Type) of
                                ok ->
                                    case validate_modules(Modules) of
                                        ok ->
                                            case validate_significant(Significant) of
                                                ok ->
                                                    {ok, {Start, Restart, Shutdown, Type, Modules}};
                                                {error, _} = Error -> Error
                                            end;
                                        {error, _} = Error -> Error
                                    end;
                                {error, _} = Error -> Error
                            end;
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

validate_start({M, F, A}) when is_atom(M), is_atom(F), is_list(A) -> ok;
validate_start(MFA) -> {error, {invalid_mfa, MFA}}.

validate_restart(permanent) -> ok;
validate_restart(transient) -> ok;
validate_restart(temporary) -> ok;
validate_restart(Restart) -> {error, {invalid_restart_type, Restart}}.

validate_shutdown(brutal_kill) -> ok;
validate_shutdown(infinity) -> ok;
validate_shutdown(Shutdown) when is_integer(Shutdown), Shutdown >= 0 -> ok;
validate_shutdown(Shutdown) -> {error, {invalid_shutdown, Shutdown}}.

validate_type(worker) -> ok;
validate_type(supervisor) -> ok;
validate_type(Type) -> {error, {invalid_child_type, Type}}.

validate_modules(dynamic) -> ok;
validate_modules(Mods) when is_list(Mods) ->
    case lists:all(fun is_atom/1, Mods) of
        true -> ok;
        false -> {error, {invalid_modules, Mods}}
    end;
validate_modules(Mods) -> {error, {invalid_modules, Mods}}.

validate_significant(false) -> ok;
validate_significant(Significant) -> {error, {invalid_significant, Significant}}.

handle_start_child({{M, F, Args} = MFA, Restart, Shutdown, Type, Modules}, 
                   #state{extra_arguments = Extra} = State) ->
    case start_child(M, F, Extra ++ Args) of
        {ok, Pid, _Info} ->
            NewState = save_child(Pid, MFA, Restart, Shutdown, Type, Modules, State),
            {reply, {ok, Pid, _Info}, NewState};
        {ok, Pid} ->
            NewState = save_child(Pid, MFA, Restart, Shutdown, Type, Modules, State),
            {reply, {ok, Pid}, NewState};
        ignore ->
            {reply, ignore, State};
        {error, _} = Error ->
            {reply, Error, State};
        Other ->
            {reply, {error, Other}, State}
    end.

start_child(M, F, A) ->
    try
        apply(M, F, A)
    catch
        Kind:Reason:Stacktrace ->
            {error, exit_reason(Kind, Reason, Stacktrace)}
    end.

exit_reason(exit, Reason, _) -> Reason;
exit_reason(error, Reason, Stack) -> {Reason, Stack};
exit_reason(throw, Value, Stack) -> {{nocatch, Value}, Stack}.

save_child(Pid, MFA, Restart, Shutdown, Type, Modules, #state{children = Children} = State) ->
    MFA1 = case Restart of
        temporary -> setelement(3, MFA, undefined);
        _ -> MFA
    end,
    State#state{children = maps:put(Pid, {MFA1, Restart, Shutdown, Type, Modules}, Children)}.

count_children_stats(Children) ->
    maps:fold(
        fun(_Pid, Child, {Active, Workers, Supervisors}) ->
            case Child of
                {restarting, {_, _, _, worker, _}} ->
                    {Active, Workers + 1, Supervisors};
                {restarting, {_, _, _, supervisor, _}} ->
                    {Active, Workers, Supervisors + 1};
                {_, _, _, worker, _} ->
                    {Active + 1, Workers + 1, Supervisors};
                {_, _, _, supervisor, _} ->
                    {Active + 1, Workers, Supervisors + 1}
            end
        end,
        {0, 0, 0},
        Children
    ).

maybe_restart_child(Pid, Reason, #state{children = Children} = State) ->
    case maps:find(Pid, Children) of
        {ok, {_, Restart, _, _, _} = Child} ->
            maybe_restart_child(Restart, Reason, Pid, Child, State);
        error ->
            {ok, State}
    end.

maybe_restart_child(permanent, Reason, Pid, Child, State) ->
    report_error(child_terminated, Reason, Pid, Child, State),
    restart_child(Pid, Child, State);

maybe_restart_child(_, normal, Pid, _Child, State) ->
    {ok, delete_child(Pid, State)};

maybe_restart_child(_, shutdown, Pid, _Child, State) ->
    {ok, delete_child(Pid, State)};

maybe_restart_child(_, {shutdown, _}, Pid, _Child, State) ->
    {ok, delete_child(Pid, State)};

maybe_restart_child(transient, Reason, Pid, Child, State) ->
    report_error(child_terminated, Reason, Pid, Child, State),
    restart_child(Pid, Child, State);

maybe_restart_child(temporary, Reason, Pid, Child, State) ->
    report_error(child_terminated, Reason, Pid, Child, State),
    {ok, delete_child(Pid, State)}.

delete_child(Pid, #state{children = Children} = State) ->
    State#state{children = maps:remove(Pid, Children)}.

restart_child(Pid, Child, State) ->
    case add_restart(State) of
        {ok, #state{strategy = Strategy} = NewState} ->
            case restart_child_impl(Strategy, Pid, Child, NewState) of
                {ok, NewState2} ->
                    {ok, NewState2};
                {try_again, NewState2} ->
                    self() ! {'$gen_restart', Pid},
                    {ok, NewState2}
            end;
        {shutdown, NewState} ->
            report_error(shutdown, reached_max_restart_intensity, Pid, Child, NewState),
            {shutdown, delete_child(Pid, NewState)}
    end.

restart_child_impl(one_for_one, CurrentPid, {{M, F, Args} = MFA, Restart, Shutdown, Type, Modules} = Child, 
                   #state{extra_arguments = Extra} = State) ->
    case start_child(M, F, Extra ++ Args) of
        {ok, Pid, _} ->
            State1 = delete_child(CurrentPid, State),
            {ok, save_child(Pid, MFA, Restart, Shutdown, Type, Modules, State1)};
        {ok, Pid} ->
            State1 = delete_child(CurrentPid, State),
            {ok, save_child(Pid, MFA, Restart, Shutdown, Type, Modules, State1)};
        ignore ->
            {ok, delete_child(CurrentPid, State)};
        {error, Reason} ->
            report_error(start_error, Reason, {restarting, CurrentPid}, Child, State),
            State1 = State#state{children = maps:put(CurrentPid, {restarting, Child}, State#state.children)},
            {try_again, State1}
    end.

add_restart(#state{max_seconds = MaxSeconds, max_restarts = MaxRestarts, restarts = Restarts} = State) ->
    Now = erlang:monotonic_time(second),
    Restarts1 = add_restart_time([Now | Restarts], Now, MaxSeconds),
    State1 = State#state{restarts = Restarts1},
    
    case length(Restarts1) =< MaxRestarts of
        true -> {ok, State1};
        false -> {shutdown, State1}
    end.

add_restart_time(Restarts, Now, Period) ->
    [Then || Then <- Restarts, Now =< Then + Period].

terminate_children(Children, State) ->
    {Pids, Times, Stacks} = monitor_children(Children),
    Size = maps:size(Pids),
    
    Timers = lists:foldl(
        fun({Time, PidList}, Acc) ->
            Timer = erlang:start_timer(Time * 1000, self(), kill),
            maps:put(Timer, PidList, Acc)
        end,
        #{},
        maps:to_list(Times)
    ),
    
    Stacks1 = wait_children(Pids, Size, Timers, Stacks),
    
    lists:foreach(
        fun({Pid, {Child, Reason}}) ->
            report_error(shutdown_error, Reason, Pid, Child, State)
        end,
        maps:to_list(Stacks1)
    ),
    
    ok.

monitor_children(Children) ->
    maps:fold(
        fun
            (_Pid, {restarting, _}, Acc) ->
                Acc;
            (Pid, {_, Restart, _, _, _} = Child, {Pids, Times, Stacks}) ->
                case monitor_child(Pid) of
                    ok ->
                        Times1 = exit_child(Pid, Child, Times),
                        {maps:put(Pid, Child, Pids), Times1, Stacks};
                    {error, normal} when Restart =/= permanent ->
                        {Pids, Times, Stacks};
                    {error, Reason} ->
                        {Pids, Times, maps:put(Pid, {Child, Reason}, Stacks)}
                end
        end,
        {#{}, #{}, #{}},
        Children
    ).

monitor_child(Pid) ->
    Ref = erlang:monitor(process, Pid),
    unlink(Pid),
    
    receive
        {'EXIT', Pid, Reason} ->
            receive
                {'DOWN', Ref, process, Pid, _} -> {error, Reason}
            end
    after 0 ->
        ok
    end.

exit_child(Pid, {_, _, Shutdown, _, _}, Times) ->
    case Shutdown of
        brutal_kill ->
            exit(Pid, kill),
            Times;
        infinity ->
            exit(Pid, shutdown),
            Times;
        Time when is_integer(Time) ->
            exit(Pid, shutdown),
            maps:update_with(Time, fun(Pids) -> [Pid | Pids] end, [Pid], Times)
    end.

wait_children(_Pids, 0, Timers, Stacks) ->
    lists:foreach(
        fun({Timer, _}) ->
            erlang:cancel_timer(Timer),
            receive
                {timeout, Timer, kill} -> ok
            after 0 ->
                ok
            end
        end,
        maps:to_list(Timers)
    ),
    Stacks;

wait_children(Pids, Size, Timers, Stacks) ->
    receive
        {'DOWN', _Ref, process, Pid, Reason} ->
            case maps:find(Pid, Pids) of
                {ok, Child} ->
                    Stacks1 = wait_child(Pid, Child, Reason, Stacks),
                    wait_children(Pids, Size - 1, Timers, Stacks1);
                error ->
                    wait_children(Pids, Size, Timers, Stacks)
            end;
        {timeout, Timer, kill} ->
            case maps:find(Timer, Timers) of
                {ok, PidList} ->
                    lists:foreach(fun(Pid) -> exit(Pid, kill) end, PidList),
                    wait_children(Pids, Size, maps:remove(Timer, Timers), Stacks);
                error ->
                    wait_children(Pids, Size, Timers, Stacks)
            end
    end.

wait_child(Pid, {_, _, brutal_kill, _, _} = Child, Reason, Stacks) ->
    case Reason of
        killed -> Stacks;
        _ -> maps:put(Pid, {Child, Reason}, Stacks)
    end;

wait_child(Pid, {_, Restart, _, _, _} = Child, Reason, Stacks) ->
    case Reason of
        {shutdown, _} -> Stacks;
        shutdown -> Stacks;
        normal when Restart =/= permanent -> Stacks;
        _ -> maps:put(Pid, {Child, Reason}, Stacks)
    end.

report_error(Error, Reason, Pid, Child, #state{name = Name, extra_arguments = Extra}) ->
    error_logger:error_report(supervisor_report, [
        {supervisor, Name},
        {errorContext, Error},
        {reason, Reason},
        {offender, extract_child(Pid, Child, Extra)}
    ]).

extract_child(Pid, {{M, F, Args}, Restart, Shutdown, Type, _Modules}, Extra) ->
    [
        {pid, Pid},
        {id, undefined},
        {mfargs, {M, F, Extra ++ Args}},
        {restart_type, Restart},
        {shutdown, Shutdown},
        {child_type, Type}
    ].

call(Supervisor, Request) ->
    gen_server:call(Supervisor, Request, infinity).