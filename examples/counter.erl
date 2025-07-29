-module(counter).
-behaviour(gen_server).

%% API
-export([start_link/1, inc/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%====================================================================
%% API
%%====================================================================

start_link(Initial) ->
    gen_server:start_link(?MODULE, Initial, []).

inc(Pid) ->
    gen_server:call(Pid, inc).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init(Initial) ->
    {ok, Initial}.

handle_call(inc, _From, Count) ->
    {reply, Count, Count + 1};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.