%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2014, Tony Rogvall
%%% @doc
%%%    Hex main processing server
%%% @end
%%% Created :  3 Feb 2014 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(hex_server).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([output/2, input/2]).

-include("../include/hex.hrl").

-define(SERVER, ?MODULE).
-define(TABLE, hex_table).

-record(state, {
	  tab :: ets:tab(),
	  input_rules = [] :: [#hex_rule{}],
	  output :: [dict()]
	 }).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    Tab = ets:new(?TABLE, [named_table]),
    {ok, #state{ tab = Tab,
		 input_rules = [],
		 output = dict:new() }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(Signal=#hex_signal{}, State) ->
    run(Signal, State#state.input_rules),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

input(I, Value) when is_integer(I); is_atom(I) ->
    io:format("input ~w ~w\n", [I, Value]),
    try ets:lookup({input,I}, ?TABLE) of
	[] ->
	    io:format("warning: hex_input ~w not running\n", [I]),
	    ignore;
	Fsm ->
	    gen_fms:send_event(Fsm, Value)
    catch 
	error:badarg ->
	    io:format("warning: hex_server not running\n", []),
	    ignore
    end.

output(O, Value) when is_integer(O) ->
    io:format("output ~w ~w\n", [O, Value]),
    try ets:lookup({output,O}, ?TABLE) of
	[] -> 
	    io:format("warning: output ~w not running\n", [O]),
	    ignore;
	Fsm ->
	    gen_fms:send_event(Fsm, Value)
    catch
	error:badarg ->
	    io:format("warning: hex_server not running\n", []),
	    ignore
    end.


run(Signal, Rules) when is_record(Signal, hex_signal) ->
    run_(Signal, Rules).

run_(Signal, [Rule|Rules]) ->
    case match_rule(Signal, Rule) of
	{true,Value} ->
	    Src = Signal#hex_signal.source,
	    V = case Signal#hex_signal.type of
		    ?HEX_DIGITAL -> {digital,Value,Src};
		    ?HEX_ANALOG ->  {analog,Value,Src};
		    ?HEX_ENCODER -> {encoder,Value,Src};
		    Type -> {Type,Value,Src}
		end,
	    input(Rule#hex_rule.label, V),
	    run_(Signal, Rules);
	false ->
	    run_(Signal, Rules)
    end;
run_(_Signal, []) ->
    ok.

match_rule(Signal, Rule) ->
    case match_(Signal#hex_signal.id, Rule#hex_rule.id) andalso 
	match_(Signal#hex_signal.chan, Rule#hex_rule.chan) andalso 
	match_(Signal#hex_signal.type, Rule#hex_rule.type) of
	true ->
	    case match_(Signal#hex_signal.value, Rule#hex_rule.value) of
		true -> {true, Signal#hex_signal.value};
		false -> false
	    end;
	false ->
	    false
    end.

match_(A, A) -> true;
match_({mask,Mask,Match}, A) -> A band Mask =:= Match;
match_({range,Low,High}, A) -> (A >= Low) andalso (A =< High);
match_({'not',Cond}, A) -> not match_(Cond,A);
match_({'and',C1,C2}, A) -> match_(C1,A) andalso match_(C2,A);
match_({'or',C1,C2}, A) -> match_(C1,A) orelse match_(C2,A);
match_([Cond|Cs], A) -> match_(Cond,A) andalso match_(Cs, A);
match_([], _A) -> true.
