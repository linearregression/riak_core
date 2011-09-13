%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011 Basho Technologies, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc A "reduce"-like fitting (in the MapReduce sense) for Riak KV
%%      MapReduce compatibility.  See riak_pipe_w_reduce.erl for more
%%      docs: this module is a stripped-down version of that one.
-module(riak_kv_w_reduce).
-behaviour(riak_pipe_vnode_worker).

-export([init/2,
         process/3,
         done/1,
         archive/1,
         handoff/2,
         validate_arg/1]).
-export([chashfun/1, reduce_compat/1]).
%% Special export for riak_pipe_fitting
-export([no_input_run_reduce_once/0]).

-include_lib("riak_pipe/include/riak_pipe.hrl").
-include_lib("riak_pipe/include/riak_pipe_log.hrl").

-include("riak_kv_js_pools.hrl").

-record(state, {acc :: list(),
                delay :: integer(),
                delay_max :: integer(),
                p :: riak_pipe_vnode:partition(),
                fd :: riak_pipe_fitting:details()}).
-opaque state() :: #state{}.

-define(DEFAULT_JS_RESERVE_ATTEMPTS, 10).

%% @doc Setup creates an empty list accumulator and
%%      stashes away the `Partition' and `FittingDetails' for later.
-spec init(riak_pipe_vnode:partition(),
           riak_pipe_fitting:details()) ->
         {ok, state()}.
init(Partition, #fitting_details{options=Options} = FittingDetails) ->
    DelayMax = calc_delay_max(FittingDetails),
    Acc = case proplists:get_value(pipe_fitting_no_input, Options) of
              true ->
                  %% AZ 479: Riak KV Map/Reduce compatibility: call reduce
                  %% function once when no input is received by fitting.
                  %% Note that the partition number given to us is bogus.
                  reduce([], #state{fd=FittingDetails},"riak_kv_w_reduce init");
              _ ->
                  []
          end,
    {ok, #state{acc=Acc, delay=0, delay_max = DelayMax,
                p=Partition, fd=FittingDetails}}.

%% @doc Process looks up the previous result for the `Key', and then
%%      evaluates the funtion on that with the new `Input'.
-spec process(term(), boolean(), state()) -> {ok, state()}.
process(Input, _Last,
        #state{acc=OldAcc, delay=Delay, delay_max=DelayMax}=State) ->
    InAcc = [Input|OldAcc],
    if Delay + 1 >= DelayMax ->
            OutAcc = reduce(InAcc, State, "reducing"),
            {ok, State#state{acc=OutAcc, delay=0}};
       true ->
            {ok, State#state{acc=InAcc, delay=Delay + 1}}
    end.

%% @doc Unless the aggregation function sends its own outputs, done/1
%%      is where all outputs are sent.
-spec done(state()) -> ok.
done(#state{acc=Acc0, delay=Delay, p=Partition, fd=FittingDetails} = S) ->
    Acc = if Delay == 0 ->
                  Acc0;
             true ->
                  reduce(Acc0, S, "done()")
          end,
    [ riak_pipe_vnode_worker:send_output(O, Partition, FittingDetails)
      || O <- Acc ],
    ok.

%% @doc The archive is the accumulator.
-spec archive(state()) -> {ok, list()}.
archive(#state{acc=Acc}) ->
    %% just send state of reduce so far
    {ok, Acc}.

%% @doc The handoff merge is simply an accumulator list.  The reduce
%%      function is also re-evaluated for the key, such that {@link
%%      done/1} still has the correct value to send, even if no more
%%      inputs arrive.
-spec handoff(list(), state()) -> {ok, state()}.
handoff(HandoffAcc, #state{acc=Acc}=State) ->
    %% for each Acc, add to local accs;
    NewAcc = handoff_acc(HandoffAcc, Acc, State),
    {ok, State#state{acc=NewAcc}}.

-spec handoff_acc([term()], [term()], state()) -> [term()].
handoff_acc(HandoffAcc, LocalAcc, State) ->
    InAcc = HandoffAcc++LocalAcc,
    reduce(InAcc, State, "reducing handoff").

%% @doc Actually evaluate the aggregation function.
-spec reduce([term()], state(), string()) ->
         {ok, [term()]} | {error, {term(), term(), term()}}.
reduce(Inputs, #state{fd=FittingDetails}, ErrString) ->
    {rct, Fun, Arg} = FittingDetails#fitting_details.arg,
    try
        ?T(FittingDetails, [reduce], {reducing, length(Inputs)}),
        Outputs = Fun(Inputs, Arg),
        true = is_list(Outputs), %%TODO: nicer error
        ?T(FittingDetails, [reduce], {reduced, length(Outputs)}),
        Outputs
    catch Type:Error ->
            %%TODO: forward
            ?T(FittingDetails, [reduce], {reduce_error, Type, Error}),
            error_logger:error_msg(
              "~p:~p ~s:~n   ~P~n   ~P",
              [Type, Error, ErrString, Inputs, 15, erlang:get_stacktrace(), 15]),
            Inputs
    end.

%% @doc Check that the arg is a valid arity-4 function.  See {@link
%%      riak_pipe_v:validate_function/3}.
-spec validate_arg({rct, function(), term()}) -> ok | {error, iolist()}.

validate_arg({rct, Fun, _FunArg}) when is_function(Fun) ->
    validate_fun(Fun).

validate_fun(Fun) when is_function(Fun) ->
    riak_pipe_v:validate_function("arg", 2, Fun);
validate_fun(Fun) ->
    {error, io_lib:format("~p requires a function as argument, not a ~p",
                          [?MODULE, riak_pipe_v:type_of(Fun)])}.

%% @doc The preferred hashing function.  Chooses a partition based
%%      on the hash of the `Key'.
-spec chashfun({term(), term()}) -> riak_pipe_vnode:chash().
chashfun({Key,_}) ->
    chash:key_of(Key).

%% @doc Compatibility wrapper for an old-school Riak MR reduce function,
%%      which is an arity-2 function `fun(InputList, SpecificationArg)'.

reduce_compat({jsanon, {Bucket, Key}})
  when is_binary(Bucket), is_binary(Key) ->
    reduce_compat({qfun, js_runner({jsanon, stored_source(Bucket, Key)})});
reduce_compat({jsanon, Source})
  when is_binary(Source) ->
    reduce_compat({qfun, js_runner({jsanon, Source})});
reduce_compat({jsfun, Name})
  when is_binary(Name) ->
    reduce_compat({qfun, js_runner({jsfun, Name})});
reduce_compat({strfun, {Bucket, Key}})
  when is_binary(Bucket), is_binary(Key) ->
    reduce_compat({strfun, stored_source(Bucket, Key)});
reduce_compat({strfun, Source}) ->
    {allow_strfun, true} = {allow_strfun,
                            app_helper:get_env(riak_kv, allow_strfun)},
    {ok, Fun} = riak_kv_mrc_pipe:compile_string(Source),
    true = is_function(Fun, 2),
    reduce_compat({qfun, Fun});
reduce_compat({modfun, Module, Function}) ->
    reduce_compat({qfun, erlang:make_fun(Module, Function, 2)});
reduce_compat({qfun, Fun}) ->
    Fun.

no_input_run_reduce_once() ->
    true.

stored_source(Bucket, Key) ->
    {ok, C} = riak:local_client(),
    {ok, Object} = C:get(Bucket, Key, 1),
    riak_object:get_value(Object).
        
js_runner(JS) ->
    fun(Inputs, Arg) ->
            JSInputs = [riak_kv_mapred_json:jsonify_not_found(I)
                        || I <- Inputs],
            JSCall = {JS, [JSInputs, Arg]},
            case riak_kv_js_manager:blocking_dispatch(
                   ?JSPOOL_REDUCE, JSCall, ?DEFAULT_JS_RESERVE_ATTEMPTS) of
                {ok, Results0}  ->
                    [riak_kv_mapred_json:dejsonify_not_found(R)
                     || R <- Results0];
                {error, no_vms} ->
                    %% will be caught by process/3, or will blow up done/1
                    throw(no_js_vms)
            end
    end.

calc_delay_max(#fitting_details{arg = {rct, _ReduceFun, ReduceArg}}) ->
    Props = case ReduceArg of
                L when is_list(L) -> L;         % May or may not be a proplist
                _                 -> []
            end,
    AppMax = app_helper:get_env(riak_kv, mapred_reduce_phase_batch_size, 1),
    case proplists:get_value(reduce_phase_only_1, Props) of
        true ->
            an_atom_is_always_bigger_than_an_integer_so_make_1_huge_batch;
        _ ->
            proplists:get_value(reduce_phase_batch_size,
                                Props, AppMax)
    end.
