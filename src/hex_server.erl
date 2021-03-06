%%% coding: latin-1
%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2017, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @author Malotte W Lönne <malotte@malotte.net>
%%% @doc
%%%    Hex main processing server
%%% Created :  3 Feb 2014 by Tony Rogvall
%%% @end
%%%-------------------------------------------------------------------
-module(hex_server).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% configuration
-export([reload/0, 
	 load/1,
	 add/1,
	 remove/0]).
-export([subscribe/1,
	 unsubscribe/0]).
-export([inform/2]).

% action
-export([output/3, 
	 input/2, 
	 event/2, 
	 digital_event_and_transmit/2, 
	 analog_event_and_transmit/2, 
	 encoder_event_and_transmit/2, 
	 feed_event_and_transmit/2, 
	 transmit/2,
	 alarm_confirm/1]).

-export([match_value/2, 
	 match_pattern/2,
	 match_pattern/3,
	 match_bin_pattern/3
	]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).


%% test
-export([event_list/0]).
-export([event_signal/1]).
-export([output2pid/1]).
-export([input2pid/1]).
-export([input_active/2]).
-export([input2outputs/1]).
-export([input2output_pids/1]).
-export([dump/0,
	 dump_map/0]).
-export([clean/1]).

-include("../include/hex.hrl").

-define(is_label(X),
	(is_atom((X)) orelse is_integer((X)) orelse
	 is_atom(hd((X))) orelse is_integer(hd((X))))).

-define(SERVER, ?MODULE).
-define(TABLE, hex_table).
-define(OWNERTABLE, hex_item_owners).

%% HARD DEBUG
-define(dbg(F), ok).
-define(dbg(F,A), ok).
%% -define(dbg(F,A), io:format((F),(A))).
%% -define(dbg(F), io:format((F))).

-type config() :: term().

-record(map_item,
	{
	  label          :: label(),
	  nodeid         :: uint32(),  %% remote id
	  channel        :: uint8(),   %% remote channel number
	  type = dynamic :: static | dynamic 
	}).

-record(int_event,
	{
	  label          :: label(),
	  ref            :: reference(),
	  app            :: atom(),
	  app_flags      :: [{Key::atom(), Value::term()}],
	  signal         :: #hex_signal{},
	  alarm=0        :: integer(), %% alarm id (0=ok)
	  analog_value=0 :: integer(),
	  state=0        :: integer(),
	  step_value = 0 :: integer(), %% (Max:16 << 16 | Current:16)
	  active=false   :: boolean()  %% status of id:chan 
	}).

-record(subscriber,
	{
	  pid  :: pid(),
	  mon  :: reference(),
	  cb :: {Module::atom(),Function::atom()} | undefined,
	  options=[] :: [{Key::atom(), Value::term()}]
	}).
		  
-record(state, {
	  config = default :: default | {file,string()} | [config()],
	  nodeid = 0       :: integer(),
	  tab              :: ets:tab(),
	  owner_table      :: ets:tab(),
	  out_list = []    :: [{Label::label(), Pid::pid()}],
	  in_list  = []    :: [{Label::label(), Pid::pid()}],
	  evt_list = []    :: [#int_event{}],
	  map = []         :: [#map_item{}],
	  transmit_rules = []  :: [#hex_transmit{}],
	  input_rules = [] :: [#hex_input{}],
	  plugin_up = []   :: [{App::atom(), Mon::reference()}],
	  plugin_down = [] :: [App::atom()],
	  subs = []        :: [#subscriber{}],
	  owners = []      :: [{Pid::pid(), Mon::reference()}]
	 }).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

%%%===================================================================
%%% API
%%%===================================================================

reload() ->
    gen_server:call(?SERVER, reload).

load(File) 
  when is_list(File) ->
    gen_server:call(?SERVER, {load, File}).

add(Config)  
  when is_list(Config) ->
    case is_up() of
	true ->
	    gen_server:call(?SERVER, {add, Config, self()});
	false ->
	    {error, not_up}
    end.

remove()  ->
    case is_up() of
	true ->
	    gen_server:call(?SERVER, {remove, self()});
	false ->
	    {error, not_up}
    end.

subscribe(Args) ->
    case is_up() of
	true ->
	    gen_server:call(?SERVER, {subscribe, self(), Args});
	false ->
	    {error, not_up}
    end.

unsubscribe() ->
    case is_up() of
	true ->
	    gen_server:call(?SERVER, {unsubscribe, self()});
	false ->
	    {error, not_up}
    end.

inform(Type, Options)   
  when is_atom(Type), is_list(Options)->
    ?SERVER ! {inform, Type, Options, self()}.

event_list() ->
    gen_server:call(?SERVER, event_list).
    
event_signal(Label) ->
    gen_server:call(?SERVER, {event_signal, Label}).
    
digital_event_and_transmit(Label, Value) ->
    gen_server:call(?SERVER, {digital_event_and_transmit, Label, Value}).

analog_event_and_transmit(Label, Value) ->
    gen_server:call(?SERVER, {analog_event_and_transmit, Label, Value}).

encoder_event_and_transmit(Label, Value) ->
    gen_server:call(?SERVER, {encoder_event_and_transmit, Label, Value}).

feed_event_and_transmit(Label, Value) ->
    gen_server:call(?SERVER, {feed_event_and_transmit, Label, Value}).

alarm_confirm(Label) ->
    gen_server:call(?SERVER, {alarm_confirm, Label}).
    
input_active(Label, Active) ->
    gen_server:call(?SERVER, {input_active, Label, Active}).
    
output2pid(Channel) ->
    gen_server:call(?SERVER, {output2pid, Channel}).

input2pid(Label) ->
    gen_server:call(?SERVER, {input2pid, Label}).

input2outputs(Label) ->
    gen_server:call(?SERVER, {input2outputs, Label}).

input2output_pids(Label) ->
    gen_server:call(?SERVER, {input2output_pids, Label}).

dump() ->
    gen_server:call(?SERVER, dump).

dump_map() ->
    gen_server:call(?SERVER, dump_map).


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
init(Options) ->
    Tab = ets:new(?TABLE, [named_table]),
    OwnerTab = ets:new(?OWNERTABLE, [bag, named_table]),
    Nodeid = proplists:get_value(nodeid, Options, 1),
    Config =
	case proplists:get_value(config, Options, default) of
	    default ->
		{file, "local.conf"};
	    ConfigOpt ->
		case hex:is_string(ConfigOpt) of
		    true -> {file, hex:text_expand(ConfigOpt,[])};
		    false -> ConfigOpt
		end
	end,
    Map = create_map(proplists:get_value(map, Options, []),[]),

    lager:debug("starting hex_server nodeid=~.16B, config=~p",
		[Nodeid, Config]),

    S0 = #state{ nodeid = Nodeid,
		 config = Config,
		 map = Map,
		 tab = Tab,
		 owner_table = OwnerTab,
		 input_rules = []
	       },
    self() ! reload,
    ?dbg("---------------------\n"
	 " HEX_SERVER STARTED  \n"
	 "---------------------\n"),
    {ok, S0}.


create_map([], Acc) ->
    Acc;
create_map([{Label, CobId, Chan} | Rest], Acc) ->
    create_map(Rest, [#map_item {label = Label,
				 nodeid = hex_config:pattern(CobId),
				 channel = Chan,
				 type = static} | Acc]).

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
handle_call({load,File} = M, _From, State) ->
    lager:debug("message ~p", [M]),
    case hex:is_string(File) of
	true ->
	    File1 = hex:text_expand(File,[]),
	    case reload(File1, State) of
		{ok,State1} ->
		    {reply, ok, State1#state {config={file,File1}}};
		Error ->
		    {reply, Error, State}
	    end;
	false ->
	    {reply, {error,einval}, State}
    end;
handle_call(reload = M, _From, State) ->
    lager:debug("message ~p", [M]),
    case reload(State#state.config, State) of
	{ok,State1} ->
	    {reply, ok, State1};
	Error ->
	    {reply, Error, State}
    end;
handle_call({add, Config, Owner} = M, _From, State=#state {owners = Owners}) ->
    lager:debug("message ~p", [M]),
    case add(Config, Owner, State) of
	{ok, State1} ->
	    case lists:keyfind(Owner, 1, Owners) of
		{Owner, _Mon}->
		    {reply, {ok, self()}, State1};
		false ->
		    Mon = erlang:monitor(process, Owner),
	    	    {reply, {ok, self()}, 
		     State1#state {owners = [{Owner, Mon} | Owners]}}
	    end;
	Error ->
	    {reply, Error, State}
    end;
handle_call({remove, Pid} = M, _From, State=#state {owners = Owners}) ->
    lager:debug("message ~p", [M]),
    case lists:keytake(Pid, 1, Owners) of
	false ->
	    lager:debug("unknown owner ~p",[Pid]),
	    {reply, ok, State};
	{value, {Pid, Mon}, NewOwners} ->
	    erlang:demonitor(Mon, [flush]),
	    State1 = remove(Pid, State),
	    ets:delete(State1#state.owner_table, Pid),
	    {reply, ok, State1#state {owners = NewOwners}}
	end;
handle_call({join,Pid,AppName}, _From, State) 
  when is_pid(Pid), is_atom(AppName) ->
    lager:info("plugin ~s [~w] joined", [AppName,Pid]),
    AppMon = erlang:monitor(process,Pid),
    %% schedule load of event defintions for App in a while
    self() ! {init_plugin, AppName},
    PluginUp = [{AppName,AppMon} | State#state.plugin_up],
    PluginDown = lists:delete(AppName, State#state.plugin_down),
    {reply, ok, State#state { plugin_up = PluginUp, plugin_down = PluginDown }};
handle_call({subscribe, Pid, Args} = M, _From, State=#state {subs = Subs}) ->
    lager:debug("message ~p", [M]),
    case lists:keyfind(Pid, #subscriber.pid, Subs) of
	S when is_record(S, subscriber) ->
	    {reply, ok, State};
	false ->
	    Mon = erlang:monitor(process, Pid),
	    Sub = case Args of
		      {Module, Function, Options} ->
			  #subscriber {pid = Pid, mon = Mon, 
				       cb = {Module, Function}, 
				       options = Options};
		      Options when is_list(Options) ->
			  #subscriber {pid = Pid, mon = Mon, 
				       options = Options}
		      end,
	    {reply, ok, State#state {subs = [Sub | Subs]}}
    end;
handle_call({unsubscribe, Pid} = M, _From, State=#state {subs = Subs}) ->
    lager:debug("message ~p", [M]),
    case lists:keytake(Pid, #subscriber.pid, Subs) of
	false ->
	    {reply, ok, State};
	{value, #subscriber {mon = Mon}, NewSubs} ->
	    erlang:demonitor(Mon, [flush]),
	    {reply, ok, State#state {subs = NewSubs}}
    end;
handle_call({inform, Type, Options} = M, _From, 
	    State=#state {subs = Subs}) ->
    lager:debug("message ~p from ~p", [M, _From]),
    Event = [{'event-type',Type}] ++ Options,
    inform_subscribers(Event, Subs),
    {reply, ok, State};
    
handle_call(event_list = M, _From, State=#state {evt_list = EList}) ->
    lager:debug("message ~p", [M]),
    List = [{E#int_event.label, E#int_event.signal} || E <- EList],
    {reply, {ok, List}, State};
handle_call({event_signal, Label} = M, _From, State=#state {evt_list = EList}) ->
    lager:debug("message ~p", [M]),
    case lists:keyfind(Label, #int_event.label, EList) of
	#int_event {signal = Signal} ->
	    {reply, {ok, Signal}, State};
	false ->
	    lager:debug("Unknown event ~p", [Label]),
	    {reply, {error, unknown_event}, State}
    end;
handle_call({input_active, Label, Active} = M, _From, 
	    State=#state {input_rules = IList}) ->
    lager:debug("message ~p", [M]),
    case lists:keytake(Label, #hex_input.label, IList) of
	{value, I=#hex_input {flags = Flags}, Rest} ->
	    case lists:keyfind(active, 1, Flags) of
		{active, Active} ->
		    %% no change
		    {reply, ok, State};
		{active, _Other} ->
		    NewFlags = 
			lists:keyreplace(active, 1, Flags, {active, Active}),
		    NewI = I#hex_input {flags = NewFlags},
		    {reply, ok, State#state {input_rules = [NewI | Rest]}};
		false ->
		    NewI = I#hex_input {flags = [{active, Active} | Flags]},
		    {reply, ok, State#state {input_rules = [NewI | Rest]}}
	    end;
	false ->
	    {reply, {error, unknown_input}, State}
    end;
handle_call({input2pid, Label}, _From, 
	    State=#state {in_list = IList}) ->
    lager:debug("input2pid: ~p", [Label]),
    {reply, to_pid(Label, IList), State};
handle_call({output2pid, Channel}, _From, 
	    State=#state {out_list = OList}) ->
    lager:debug("output2pid: ~p", [Channel]),
    {reply, to_pid(Channel, OList), State};
handle_call({input2outputs, Label}, _From, 
	    State=#state {input_rules = IList}) ->
    lager:debug("input2outputs: ~p", [Label]),
    {reply, input2outputs(Label, IList), State};
handle_call({input2output_pids, Label}, _From, 
	    State=#state {input_rules = IList, out_list = OList}) ->
    lager:debug("input2output_pids: ~p", [Label]),
    case input2outputs(Label, IList) of
	List when is_list(List) ->
	    Reply = [to_pid(V, OList) || {K,V} <- List, K =:= channel],
	    {reply, Reply, State};
	{error, _Reason} = E -> {reply, E, State}
    end;
handle_call({digital_event_and_transmit, Label, Value}, _From, 
	    State=#state {evt_list = EList}) ->
    lager:debug("event_and_transmit: ~p", [Label]),
    case {lists:keyfind(Label, #int_event.label, EList), Value} of
	{#int_event {signal = (#hex_signal {chan = LChan,
					    type = ?HEX_ALARM_CNFRM})}, 1}
	  when LChan > 254 ->
	    %% This is probably an event for confirming 
	    %% a power_zone alarm, ignore
	    lager:debug("channel ~p not possible", [LChan]),
	    {reply, ok, State};
	{#int_event {signal = (Signal=#hex_signal {type = Type}), 
		     alarm = Alarm}, 1}
	  when (Alarm > 0) andalso 
	       (Type =:= ?HEX_DIGITAL orelse Type =:= ?HEX_ANALOG) ->
	    Signal1 = Signal#hex_signal {value = Value, type = ?HEX_DIGITAL},
	    lager:debug("alarm present for ~p, sending confirm ~s",
			[Label, format_signal(Signal1)]),
	    alarm_confirm(Label, Signal1, State),
	    NewState = run_event(Signal1, <<>>, State#state.input_rules, State),
	    {reply, ok, NewState};
	{#int_event {signal = Signal},_} ->
	    Signal1 = Signal#hex_signal {value = Value, type = ?HEX_DIGITAL},
	    run_transmit(Signal1, State#state.transmit_rules),
	    NewState = run_event(Signal1, <<>>, State#state.input_rules, State),
	    {reply, ok, NewState};
	{false, _} ->
	    lager:debug("Unknown label ~p", [Label]),
	    {reply, {error, unknown_event}, State}
    end;
handle_call({analog_event_and_transmit, Label, Value}, _From, 
	    State=#state {evt_list = EList}) ->
    lager:debug("analog_event_and_transmit: ~p", [Label]),
    case {lists:keyfind(Label, #int_event.label, EList), Value} of
	{#int_event {signal = (#hex_signal {chan = LChan,
					    type = ?HEX_ALARM_CNFRM})}, 1}
	  when LChan > 254 ->
	    %% This is probably an event for confirming 
	    %% a power_zone alarm, ignore
	    lager:debug("channel ~p not possible", [LChan]),
	    {reply, ok, State};
	{#int_event {signal = (Signal=#hex_signal {type = Type}), 
		     alarm = Alarm}, 1}
	  when (Alarm > 0) andalso 
	       (Type =:= ?HEX_DIGITAL orelse Type =:= ?HEX_ANALOG) ->
	    Signal1 = Signal#hex_signal {value = Value, type = ?HEX_ANALOG},
	    lager:debug("alarm present for ~p, sending confirm ~s",
			[Label, format_signal(Signal1)]),
	    alarm_confirm(Label, Signal1, State),
	    NewState = run_event(Signal1, <<>>, State#state.input_rules, State),
	    {reply, ok, NewState};
	{#int_event {signal = Signal},_} ->
	    lager:debug(" ~p run transmit", [Label]),
	    Signal1 = Signal#hex_signal {value = Value, type = ?HEX_ANALOG},
	    run_transmit(Signal1, State#state.transmit_rules),
	    lager:debug(" ~p run event", [Label]),
	    NewState = run_event(Signal1, <<>>, State#state.input_rules, State),
	    {reply, ok, NewState};
	{false, _} ->
	    lager:debug("Unknown label ~p", [Label]),
	    {reply, {error, unknown_event}, State}
    end;
handle_call({encoder_event_and_transmit, Label, Value}, _From, 
	    State=#state {evt_list = EList}) ->
    lager:debug("encoder_event_and_transmit: ~p", [Label]),
    case {lists:keyfind(Label, #int_event.label, EList), Value} of
	{#int_event {signal = (#hex_signal {chan = LChan,
					    type = ?HEX_ALARM_CNFRM})}, 1}
	  when LChan > 254 ->
	    %% This is probably an event for confirming 
	    %% a power_zone alarm, ignore
	    lager:debug("channel ~p not possible", [LChan]),
	    {reply, ok, State};
	{#int_event {signal = (Signal=#hex_signal {type = ?HEX_DIGITAL}), 
		     alarm = Alarm}, 1}
	  when Alarm > 0 ->
	    Signal1 = Signal#hex_signal {value = Value, type = ?HEX_ENCODER},
	    alarm_confirm(Label, Signal1, State),
	    NewState = run_event(Signal1, <<>>, State#state.input_rules, State),
	    {reply, ok, NewState};
	{#int_event {signal = Signal},_} ->
	    Signal1 = Signal#hex_signal {value = Value, type = ?HEX_ENCODER},
	    run_transmit(Signal1, State#state.transmit_rules),
	    NewState = run_event(Signal1, <<>>, State#state.input_rules, State),
	    {reply, ok, NewState};
	{false, _} ->
	    lager:debug("Unknown label ~p", [Label]),
	    {reply, {error, unknown_event}, State}
    end;
handle_call({feed_event_and_transmit, Label, Value}, _From, 
	    State=#state {evt_list = EList}) ->
    lager:debug("feed_event_and_transmit: ~p", [Label]),
    case {lists:keyfind(Label, #int_event.label, EList), Value} of
	{#int_event {signal = (#hex_signal {chan = LChan,
					    type = ?HEX_ALARM_CNFRM})}, 1}
	  when LChan > 254 ->
	    %% This is probably an event for confirming 
	    %% a power_zone alarm, ignore
	    lager:debug("channel ~p not possible", [LChan]),
	    {reply, ok, State};
	{#int_event {signal = Signal},_} ->
	    Signal1 = Signal#hex_signal {value = Value, type = ?HEX_FEED},
	    run_transmit(Signal1, State#state.transmit_rules),
	    NewState = run_event(Signal1, <<>>, State#state.input_rules, State),
	    {reply, ok, NewState};
	{false, _} ->
	    lager:debug("Unknown label ~p", [Label]),
	    {reply, {error, unknown_event}, State}
    end;
handle_call({alarm_confirm, Label}, _From, 
	    State=#state {evt_list = EList}) ->
    lager:debug("alarm_confirm: ~p", [Label]),
    case lists:keyfind(Label, #int_event.label, EList) of
	#int_event {signal = (Signal=#hex_signal {type = ?HEX_ALARM_CNFRM,
						  chan = LChan}), 
		    alarm = Alarm}
	  when LChan > 254 ->
	    lager:debug("channel ~p converted to 0", [LChan]),
	    if Alarm =:= 0 -> lager:warning("no known alarm for ~p", [Label]);
	       true -> ok
	    end,
	    alarm_confirm(Label, Signal#hex_signal {chan = 0}, State),
	    {reply, ok, State};
	#int_event {signal = Signal, alarm = Alarm} ->
	    if Alarm =:= 0 -> lager:warning("no known alarm for ~p", [Label]);
	       true -> ok
	    end,
	    alarm_confirm(Label, Signal, State),
	    {reply, ok, State};
	false ->
	    lager:debug("Unknown label ~p", [Label]),
	    {reply, {error, unknown_event}, State}
    end;
handle_call(dump, _From, State) ->
    dump_state(State),
    {reply, State, State};
handle_call(dump_map, _From, State=#state{map = Map}) ->
    dump_map(Map),
    {reply, Map, State};

handle_call(_Request, _From, State) ->
    {reply, {error, bad_call}, State}.

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
handle_cast({event,Signal=#hex_signal{},Data}, State) ->
    lager:debug("event: ~s data=~p", [format_signal(Signal),Data]),
    NewState = run_event(Signal, Data, State#state.input_rules, State),
    {noreply, NewState};

handle_cast({transmit,Signal=#hex_signal{}}, State) ->
    lager:debug("transmit: ~p", [Signal]),
    run_transmit(Signal, State#state.transmit_rules),
    {noreply, State};

handle_cast({join,Pid,AppName}, State) when is_pid(Pid),
					    is_atom(AppName) ->
    lager:info("plugin ~s [~w] joined", [AppName,Pid]),
    AppMon = erlang:monitor(process,Pid),
    %% schedule load of event defintions for App in a while
    self() ! {init_plugin, AppName},
    PluginUp = [{AppName,AppMon} | State#state.plugin_up],
    PluginDown = lists:delete(AppName, State#state.plugin_down),
    {noreply, State#state { plugin_up = PluginUp, plugin_down = PluginDown }};

handle_cast(_Cast, State) ->
    lager:debug("got cast: ~p", [_Cast]),
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
handle_info(reload, State) ->
    lager:debug("reload", []),
    case reload(State#state.config, State) of
	{ok,State1} ->
	    {noreply, State1};
	_Error ->
	    {noreply, State}
    end;

handle_info({init_plugin, AppName}, State) ->
    lager:debug("init PLUGIN: ~s", [AppName]),
    %% reload all events for Plugin AppName
    {noreply, State};

handle_info({inform, Type, Options, _From}, 
	    State=#state {subs = Subs}) ->
    lager:debug("inform: ~p ~p from ~p", [Type, Options, _From]),
    Event = [{'event-type',Type}] ++ Options,
    inform_subscribers(Event, Subs),
    {noreply, State};

handle_info({'DOWN',Ref,process,Pid,Reason}, State) ->
    case lists:keytake(Ref, 2, State#state.plugin_up) of
	false ->
	    case lists:keytake(Ref, #subscriber.mon, State#state.subs) of
		false ->
		    case lists:keytake(Ref, 2, State#state.owners) of
			false ->
			    {noreply, State};
			{value, {Pid, Ref}, NewOwners} ->
			    if Reason =/= shutdown ->
				    lager:warning("owner DOWN: ~p reason=~p",
						  [Pid,Reason]);
			       true -> ok
			    end,
			    State1 = remove(Pid, State),
			    ets:delete(State1#state.owner_table, Pid),
			    {noreply, State1#state {owners = NewOwners}}
			end;
		{value, #subscriber {pid = Pid}, NewSubs} ->
		    if Reason =/= shutdown ->
			    lager:warning("subscriber DOWN: ~p reason=~p",
					  [Pid,Reason]);
		       true -> ok
		    end,
		    {noreply, State#state { subs = NewSubs}}
	    end;
	{value,{App,_Ref},PluginUp} ->
	    if Reason =/= shutdown ->
		    lager:warning("plugin DOWN: ~s reason=~p", [App,Reason]);
	       true ->
		    ok
	    end,
	    PluginDown = [App|State#state.plugin_down],
	    {noreply, State#state { plugin_up   = PluginUp,
				    plugin_down = PluginDown }}
    end;
handle_info(_Info, State) ->
    lager:debug("got info: ~p", [_Info]),
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
is_up() ->
    case whereis(?SERVER) of
	Pid when is_pid(Pid) -> true;
	undefined -> false
    end.
    
reload({file,File}, State) ->
    ?dbg("---------------------\n"
	 " HEX_SERVER RELOAD   \n"
	 "---------------------\n"),
    case file:consult(File) of
	{ok,Config} ->
	    rescan(Config, File, self(), State);
	Error={error,Reason} ->
	    io:format("~s: file error:  ~p\n", [File,Reason]),
	    lager:error("error loading file ~s~p", [File,Reason]),
	    Error
    end;
reload(Config, State) ->
    rescan(Config, "*config*", self(), State).

add(Config, Owner, State) ->
    lager:debug("Adding ~p",[Config]),
    rescan(Config, "*add-call*", Owner, State).

rescan(Config, File, Owner, State) ->
    ?dbg("---------------------\n"
	 " HEX_SERVER RESCAN   \n"
	 "---------------------\n"),
    case hex_config:scan(Config) of
	{ok,{Evt,In,Out,Trans}} ->
	    State1 = start_outputs(Out, Owner, State),
	    State2 = start_inputs(In, Owner, State1),
	    State3 = start_events(Evt, Owner, State2),
	    State4 = start_transmits(Trans, Owner, State3),
	    ?dbg("---------------------\n"
		 " HEX_SERVER RESCAN DONE\n"
		 "---------------------\n"),
	    {ok, State4#state { input_rules = In }};
	Error={error,Reason} ->
	    io:format("~p: config error ~p\n", [?MODULE, Reason]),
	    lager:error("error config file ~s, ~p", [File,Reason]),
	    Error
    end.


start_outputs([O=#hex_output {label=L} | Out], Owner,
	      State=#state {tab = Tab, out_list = OutList}) ->
    NewOutList = 
	case ets:lookup(Tab, {output, L}) of
	    [] -> 
		start_output(O, Owner, State);
	    [_Tuple] ->
		lager:warning("output ~p already defined, skipping", [L]),
		%% Replacing ??
		OutList
	end,
    start_outputs(Out, Owner, State#state { out_list = NewOutList });
start_outputs([], _Owner, State) ->
    State.

start_output(#hex_output {label=L, flags=Flags, actions=Actions}, Owner, State) ->
    case Actions of
	{App,AppFlags} ->
	    lager:debug("start_output: ~p ~p", [App,AppFlags]),
	    start_plugin(App,out,AppFlags);
	_ when is_list(Actions) ->
	    lists:foreach(
	      fun({_Pattern,{App,AppFlags}}) ->
		      lager:debug("start_output: ~p ~p", [App,AppFlags]),
		      start_plugin(App,out,AppFlags)
	      end, Actions)
    end,
    %% nodeid and chan is needed for feedback from output
    Flags1 = [{nodeid,State#state.nodeid},{chan,L}|Flags],
    {ok,Pid} = hex_output:start_link(Flags1, Actions),
    ets:insert(State#state.tab, {{output,L}, Pid}),
    ets:insert(State#state.owner_table, {Owner, {output,L}}),
    [{L,Pid} | State#state.out_list].
    
start_inputs([I=#hex_input {label=L} | In], Owner,
	     State=#state {tab = Tab, in_list = InList}) ->
    NewInList =
	case ets:lookup(Tab, {input, L}) of
	    [] -> 
		start_input(I, Owner, State);
	    [_Tuple] ->
		lager:warning("input ~p already defined, skipping", [L]),
		%% Replacing ??
		InList
	end,
    start_inputs(In, Owner, State#state {in_list = NewInList});
start_inputs([], _Owner, State) ->
    State.

start_input(#hex_input {label=L, flags = Flags}, Owner, State) ->
    {ok,Pid} = hex_input:start_link([{id,L}|Flags]),
    ets:insert(State#state.tab, {{input,L}, Pid}),
    ets:insert(State#state.owner_table, {Owner, {input,L}}),
    [{L,Pid} | State#state.in_list].

%% start
start_events([E=#hex_event {label=L} | Evt], Owner,
	     State=#state{evt_list = EList}) ->
    NewEList =
	case lists:keyfind(L, #int_event.label, EList) of
	    false -> 
		start_event(E, Owner, State);
	    _Tuple ->
		lager:warning("event ~p already defined, skipping", [L]),
		%% Replacing ??
		EList
	end,
    start_events(Evt, Owner, State#state{evt_list = NewEList});
start_events([], _Owner, State) ->
    State.

start_event(#hex_event {label=L, app=App, app_flags=AppFlags, signal=Signal}, 
	    Owner, State=#state{evt_list = EList}) ->
    lager:debug("start_plugin: ~p ~p", [App,AppFlags]),
    case start_plugin(App, in, AppFlags) of
	ok ->
	    case App:add_event(AppFlags, Signal, ?MODULE) of
		{ok, Ref} ->
		    lager:debug("event ~w started ~w", [L, Ref]),
		    ets:insert(State#state.owner_table, {Owner, {event,L}}),
		    [#int_event{ label = L, 
				 ref = Ref, 
				 app = App,
				 app_flags = AppFlags, 
				 signal = Signal} | EList];
		Error ->
		    lager:error("unable to add_event: ~p ~p: ~p",
				[App,AppFlags,Error]),
		    EList
	    end;
	_Error ->
	    EList
    end.


start_transmits([T=#hex_transmit {label=L } | Ts], Owner,   
		State=#state {transmit_rules = Rules}) ->
    NewRules =
	case lists:keyfind(L, #hex_transmit.label, Rules) of
	    false -> 
		start_transmit(T, Owner, State);
	    _Tuple ->
		lager:warning("transmit ~p already defined, skipping", [L]),
		%% Replacing ??
		Rules
	end,
    start_transmits(Ts, Owner, State#state {transmit_rules = NewRules});
start_transmits([], _Owner, State) ->
    State.

start_transmit(T=#hex_transmit {label=L, app=App, flags=Flags}, Owner,   
	       State=#state {transmit_rules = Rules}) ->    
    case start_plugin(App, out, Flags) of
	ok ->
	    ets:insert(State#state.owner_table, {Owner, {transmit,L}}),
	    [T | State#state.transmit_rules];
	_Error ->
	    Rules
    end.

start_plugin(hex_none = App, Dir, Flags) ->
    init_plugin(App, Dir, Flags);
start_plugin(App, Dir, Flags) ->
    case hex:start_all(App) of
	{ok,[]} -> %% already started
	    init_plugin(App, Dir, Flags);
	{ok,Started} ->
	    lager:info("plugin ~w started: ~p", [App,Started]),
	    init_plugin(App, Dir, Flags);
	Error ->
	    lager:error("plugin ~w failed to start: ~p", [App, Error]),
	    Error
    end.

init_plugin(hex_none, Dir, Flags) ->
    hex_none:init_event(Dir, Flags);
init_plugin(App, Dir, Flags) ->
    lager:debug("init_event: ~p ~p", [App,Flags]),
    case App:init_event(Dir, Flags) of
	ok ->
	    lager:debug("~w:~w flags ~p initiated", [App,Dir,Flags]),
	    ok;
	Error ->
	    lager:warning("~w:~w flags ~p failed ~p", [App,Dir,Flags,Error]),
	    Error
    end.

remove(Owner, State=#state {owner_table = OwnerTab}) -> 
    remove_all(ets:lookup(OwnerTab, Owner), State).
    
remove_all([], State) ->
    lager:debug("all removed", []),
    State;
remove_all([{_Owner, {transmit, L}} | Rest], State) ->
    NewState = remove_transmit(L, State),
    remove_all(Rest, NewState);
remove_all([{_Owner, {event, L}} | Rest], State) ->
    NewState = remove_event(L, State),
    remove_all(Rest, NewState);
remove_all([{_Owner, {input, L}} | Rest], State) ->
    NewState = remove_input(L, State),
    remove_all(Rest, NewState);
remove_all([{_Owner, {output, L}} | Rest], State) ->
    NewState = remove_output(L, State),
    remove_all(Rest, NewState).

remove_transmit(L, State=#state {transmit_rules = Rules}) ->
    NewRules =
	case lists:keytake(L, #hex_transmit.label, Rules) of
	    false ->
		lager:warning("transmit ~p not found", [L]),
		Rules;
	    {value, _T, R} ->
		lager:debug("transmit ~p removed", [L]),
		R
    end,
    State#state {transmit_rules = NewRules}.

remove_event(L, State=#state {evt_list = EList, map = Map}) ->
    case lists:keytake(L, #int_event.label, EList) of
	false ->
	    lager:warning("event ~p not found", [L]),
	    State;
	{value, #int_event {ref = Ref, app = App}, NewEList} ->
	    App:del_event(Ref),
	    lager:debug("event ~p removed", [L]),
	    case lists:keytake(L, #map_item.label, Map) of
		false ->
		    State#state {evt_list = NewEList};
		{value, _M, NewMap} ->
		    lager:debug("event ~p removed from map", [L]),
		    State#state {evt_list = NewEList, map = NewMap}
	    end
    end.

remove_input(L, State=#state {tab = Tab, in_list = IList, input_rules = IRules}) ->
    ets:delete(Tab, {input, L}),
    case lists:keytake(L, 1, IList) of
	false ->
	    lager:warning("input ~p not found", [L]),
	    State;
	{value, {L, Pid}, NewIList} ->
	    hex_input:stop(Pid),
	    case lists:keytake(L, #hex_input.label, IRules) of
		false ->
		    lager:warning("input rule ~p not found", [L]),
		    State#state {in_list = NewIList};
		{value, _I, NewIRules} ->
		    lager:debug("input ~p removed", [L]),
		    State#state {in_list = NewIList, input_rules = NewIRules}
	    end
    end.

remove_output(L, State=#state {tab = Tab, out_list = OList}) ->
    ets:delete(Tab, {output, L}),
    case lists:keytake(L, 1, OList) of
	false ->
	    lager:warning("output ~p not found", [L]),
	    State;
	{value, {L, Pid}, NewOList} ->
	    hex_output:stop(Pid),
	    lager:debug("output ~p removed", [L]),
	    State#state {out_list = NewOList}
   end.


run_event(Signal, Data, Rules, State) 
  when is_record(Signal, hex_signal) ->
    run_event_(Signal, Data, Rules, State),
    case Signal#hex_signal.type of
	?HEX_POWER_ON     -> run_power_on(Signal, Rules, State);
	?HEX_OUTPUT_ADD   -> run_output_add(Signal, State);
        ?HEX_OUTPUT_DEL   -> run_output_del(Signal, State);
        ?HEX_OUTPUT_ACTIVE -> run_output_action(active, Signal, State);
        ?HEX_OUTPUT_VALUE -> run_output_action(value, Signal, State);
        ?HEX_OUTPUT_STATE -> run_output_action(state, Signal, State);
        ?HEX_OUTPUT_STEP  -> run_output_action(step, Signal, State);
	%% ?HEX_POWER_OFF -> run_power_off(Signal, Rules, State);
	%% ?HEX_WAKEUP    -> run_wakeup(Signal, Rules, State);
	?HEX_ALARM        -> run_alarm(Signal, State);
	?HEX_ALARM_CNFRM_ACK -> run_alarm_confirm_ack(Signal, State);
	?HEX_OUTPUT_ALARM  -> run_output_alarm(Signal, State);
	_ -> State
    end.

run_event_(Signal=#hex_signal {source = Src}, Data, 
	   [#hex_input {label = Label, signal = Pattern, flags = Flags} |
	    Rules],
	    State) ->
    case match_pattern(Signal, Data, Pattern) of
	{true, Type, Value} ->
	    lager:debug("matching label ~p and rule ~s",
			[Label,format_pattern(Pattern)]),
	    case active(Flags) of
		true ->
		    lager:debug("has active flag"),
		    V = {Type, Value, Src},
		    input(Label, V),
		    run_event_(Signal, Data, Rules, State);
		false ->
		    run_event_(Signal, Data, Rules, State)
	    end;
	false ->
%%	    lager:debug("no match signal ~s ~n rule ~s",
%%			[format_signal(Signal),
%%			 format_pattern(Pattern)]),
	    run_event_(Signal, Data, Rules, State)
    end;
run_event_(_Signal, _Data, [], _State) ->
    ok.

active([]) -> true;
active([{active, true} | _Flags]) -> true;
active([{active, false} | _Flags]) -> false;
active([_Flag | Flags]) -> active(Flags).
    

run_power_on(Signal=#hex_signal {id = RId}, Rules, State=#state{map = Map}) ->
    lager:debug("run_power_on: ~s", [format_signal(Signal)]),
    State1 = reset(cobid2nodeid(RId), Map, State, []),
    lager:debug("run_power_on: after reset", []),
    State2 = add_node(Signal, State1),     
    add_outputs(Signal, Rules, State2).

add_node(Signal=#hex_signal {id = RId, chan = 0}, 
	 State=#state{evt_list = Events}) ->
    lager:debug("add_node: ~.16B ", [RId]),
    %% Node has channel 0
    run_output_add(clean(hex:make_self(State#state.nodeid)),
		   hex:virtual_cc_for_node(cobid2nodeid(RId)),
		   Signal, Events, State).
	    
add_outputs(Signal, [Rule|Rules], State) ->
    RulePattern = Rule#hex_input.signal,
    if is_integer(Signal#hex_signal.id),
       Signal#hex_signal.id =:= RulePattern#hex_pattern.id,
       is_integer(RulePattern#hex_pattern.chan) ->
	    add_outputs(Rule#hex_input.flags,
			RulePattern#hex_pattern.id,
			RulePattern#hex_pattern.chan,
			State),
	    add_outputs(Signal, Rules, State);
       true ->
	    add_outputs(Signal, Rules, State)
    end;
add_outputs(_Signal, [], State) ->
    State.

add_outputs([{output,Output}|Flags], Rid, Rchan, State) ->
    case proplists:get_value(channel,Output,0) of
	Chan when is_integer(Chan), Chan > 0, Chan =< 254 ->
	    lager:debug("add output id=~.16B, chan=~w id=~.16B, rchan=~w",
		   [State#state.nodeid, Chan, Rid, Rchan]),
	    Value = (Rid bsl 8) bor Rchan,
	    Add = #hex_signal { id=hex:make_self(State#state.nodeid),
				chan=Chan,
				type=?HEX_OUTPUT_ADD,
				value=Value,
				source={output,Chan}},
	    run_transmit(Add, State#state.transmit_rules),
	    add_outputs(Flags, Rid, Rchan, State);
	_ ->
	    add_outputs(Flags, Rid, Rchan, State)
    end;
add_outputs([_|Flags], Rid, Rchan, State) ->
    add_outputs(Flags, Rid, Rchan, State);
add_outputs([], _Rid, _Rchan, _State) ->
    ok.


run_output_add(Signal=#hex_signal {id=_RId, chan=_RChan, value = Value}, 
	       State=#state {evt_list = EvtList}) ->
    lager:debug("run_output_add: ~s", [format_signal(Signal)]),
    {Id, Chan} = value2nid(Value),
    ?dbg("~8.16.0B:~3w ~8.16.0B:~w action=~w\n",
	 [clean(_RId) _RChan, clean(Id), Chan, output_add]),
    lager:debug("run_output_add: ~.16B ~p", [Id, Chan]),
    if Chan >=1, Chan =< 254 -> 
	    run_output_add(Id, Chan, Signal, EvtList, State);
       true ->
	    State
    end.

run_output_add(LId, LChan, Signal=#hex_signal {id = RId, chan = RChan}, 
	       [#int_event {label = Label, signal = S} | Events], State) 
  when is_integer(S#hex_signal.id) ->
    SigNodeId = clean(S#hex_signal.id),
    if LId =:= SigNodeId,
       LChan =:= S#hex_signal.chan ->
 	    NewState = run_output_add(cobid2nodeid(RId), RChan, Label, State),
	    run_output_add(LId, LChan, Signal, Events, NewState);
       true ->
	    run_output_add(LId, LChan, Signal, Events, State)
    end;
run_output_add(Id, LChan, Signal, [_E | Events], State) ->
    run_output_add(Id, LChan, Signal, Events, State);
run_output_add(_LId, _LChan, _Signal, [], State) ->
    State.

run_output_add(RId, RChan, Label, State=#state{map = Map}) ->
    case find_map_item(Map, Label, RId , RChan) of
	{true,_M} -> 
	    lager:debug("output-add, already mapped: ~8.16.0B:~3w ~p", 
		 [_M#map_item.nodeid,
		  _M#map_item.channel,
		  _M#map_item.label]),
	    %% Resent output_add clears alarm
	    run_alarm(RId, RChan, 0, Map, State);
	false ->
	    M = #map_item{label = Label,
			  nodeid = RId,
			  channel = RChan,
			  type = dynamic},
	    lager:debug("run_output_add: item ~8.16.0B:~3w ~p", 
			[M#map_item.nodeid,
			 M#map_item.channel,
			 M#map_item.label]),
	    State#state {map = [M | Map]}
    end.


run_output_del(Signal=#hex_signal {value = Value}, 
	       State=#state {evt_list = EvtList}) ->
    lager:debug("run_output_del: ~p", [Signal]),
    {Id, Chan} = value2nid(Value),
    lager:debug("run_output_del: ~.16B ~p", [Id, Chan]),
    if Chan >=1, Chan =< 254 -> 
	    run_output_del(Id, Chan, Signal, EvtList, State);
       true ->
	    State
    end.

run_output_del(Id, LChan, Signal=#hex_signal {id = RId, chan = RChan}, 
	       [#int_event {label = Label, signal = S} | Events], State) 
  when is_integer(S#hex_signal.id) ->
    SigNodeId = clean(S#hex_signal.id) ,
    if Id =:= SigNodeId,
       LChan =:= S#hex_signal.chan ->
	    NewState = run_output_del(cobid2nodeid(RId), RChan, Label, State), 
	    run_output_del(Id, LChan, Signal, Events, NewState);
       true ->
	    run_output_del(Id, LChan, Signal, Events, State)
    end;
run_output_del(Id, LChan, Signal,  [_E | Events], State) ->
    run_output_del(Id, LChan, Signal, Events, State);
run_output_del(_Id, _LChan, _Signal, [], State) ->
    State.

run_output_del(RId, RChan, Label, State=#state{map = Map}) ->
    case find_map_item(Map, Label, RId, RChan) of
	{true,_M} ->
	    lager:debug("run_output_del: item ~p, ~p, ~p", 
			[Label, RId, RChan]),
	    %% output_del clears alarms
	    NewState = run_alarm(RId, RChan, 0, Map, State),
	    NewMap = remove_mapped(Label, RId, RChan, Map, []),
	    NewState#state {map = NewMap};
	false ->
	    State
    end.

run_output_action(Action, 
		  Signal=#hex_signal {id = Id, chan = Chan, value = Value}, 
		  State=#state {map = Map}) ->
    lager:debug("signal ~s", [format_signal(Signal)]),
    ?dbg("~8.16.0B:~3w value=~p, action=~w\n",
	 [clean(Id), Chan, Value, Action]),
    %%Id = clean(Id0),
    run_output_action(Action, cobid2nodeid(Id), Chan, Value, Map, State).

run_output_action(_Action, _Id, _Chan, _Value, [], State) ->
    State;
run_output_action(Action, Id, Chan, Value, 
	       [#map_item {label = Label, nodeid = Id, channel = Chan} | Map], 
	       State=#state{evt_list = EList, subs = Subs}) ->
    lager:debug("event ~p, ~p ~p", [Action, Label, Value]),
    NewElist = event_action(Action, Label, Value, EList, [], Subs),
    run_output_action(Action, Id, Chan, Value, Map, 
		      State#state{evt_list = NewElist});
run_output_action(Action, Id, Chan, Value, [_MapItem | Map], State) ->
    run_output_action(Action, Id, Chan, Value, Map, State).


event_action(_Action, _Label, _Value, [], Acc, _Subs) ->
    Acc;
event_action(Action, Label, Value, 
	     [E=#int_event {label = Label} | Events], 
	     Acc, Subs) ->
    event_action(Action, Label, Value, Events, 
		 [event_action(Action, E, Value, Subs)| Acc], Subs);
event_action(Action, Label, Value, [E | Events], Acc, Subs) ->
    event_action(Action, Label, Value, Events, [E | Acc], Subs).

event_action(active, Event, Active, Subs) ->
    event_active(Event, Active, Subs);
event_action(value, Event, Value, Subs) ->
    event_value(Event, Value, Subs);
event_action(step, Event, Value, Subs) ->
    event_step(Event, Value, Subs);
event_action(state, Event, Value, Subs) ->
    event_state(Event, Value, Subs).

event_active(E=#int_event {label = Label, app = App, app_flags = AppFlags}, 
	     Active, Subs) ->
    lager:debug("output-active event ~p ~p ~p", [Label, Active, Subs]),
    App:output(AppFlags, [{output_active, Active}]),
    Event = [{'event-type','output-active'}, {label, Label}, {value, Active}],
    inform_subscribers(Event, Subs),
    E#int_event {active = (Active =/= 0)}.

event_value(E=#int_event {label = Label, app = App, app_flags = AppFlags},
	   Value, Subs) ->
    App:output(AppFlags, [{output_value, Value}]),
    Event = [{'event-type','output-value'}, {label, Label}, {value, Value}],
    inform_subscribers(Event, Subs),
    E#int_event {analog_value = Value}.

event_step(E=#int_event {label = Label, app = App, app_flags = AppFlags},
	   Value, Subs) ->
    App:output(AppFlags, [{output_step, Value}]),
    Event = [{'event-type','output-step'}, {label, Label}, {value, Value}],
    inform_subscribers(Event, Subs),
    E#int_event {step_value = Value}.

event_state(E=#int_event {label = Label, app = App, app_flags = AppFlags},
	   Value, Subs) ->
    App:output(AppFlags, [{output_state, Value}]),
    Event = [{'event-type','output-state'}, {label, Label}, {value, Value}],
    inform_subscribers(Event, Subs),
    E#int_event {state = Value}.


run_alarm(Signal=#hex_signal {id = Id, chan = Chan, value = Value}, 
	  State=#state {map = Map}) ->
    lager:debug("signal ~s", [format_signal(Signal)]),
    run_alarm(cobid2nodeid(Id), Chan, Value, Map, State).

run_alarm(Id, Chan, Alarm, 
	  [#map_item {label = Label, nodeid = Id, channel = Chan} | Map], 
	  State=#state{evt_list = EList, subs = Subs}) ->
    NewElist = event_alarm(Label, Alarm, EList, [], Subs),
    run_alarm(Id, Chan, Alarm, Map, State#state{evt_list = NewElist});
run_alarm(Id, Chan, Alarm, [_MapItem | Map], State) ->
    run_alarm(Id, Chan, Alarm, Map, State);
run_alarm(_Id, _Chan, _Alarm, [], State) ->
    State.

event_alarm(_Label, _Alarm, [], Acc, _Subs) ->
    Acc;
event_alarm(Label, Alarm, 
	    [E=#int_event {label = Label, alarm = Alarm} | Events], 
	    Acc, Subs) ->
    lager:debug("event ~p, old alarm ~p", [Label, Alarm]),
    %% No change in alarm
    event_alarm(Label, Alarm, Events, [E | Acc], Subs);
event_alarm(Label, Alarm, 
	    [E=#int_event {label = Label, app = App, app_flags = AppFlags} | 
	     Events], 
	    Acc, Subs) ->
    lager:debug("event ~p, new alarm ~p", [Label, Alarm]),
    App:output(AppFlags, [{alarm, Alarm}]),
    Event = [{'event-type','alarm'},{label, Label}, {value, Alarm}],
    inform_subscribers(Event, Subs),
    event_alarm(Label, Alarm, Events, 
		[E#int_event {alarm = Alarm} | Acc], Subs);
event_alarm(Label, Alarm, [E | Events], Acc, Subs) ->
    event_alarm(Label, Alarm, Events, [E | Acc], Subs).


alarm_confirm(Label, #hex_signal{id = Id, chan = Chan}, 
	      State=#state {map = Map}) ->
    case 
	lists:foldl(
	  fun(#map_item{label = L, nodeid = XNodeId, channel = Channel}, Acc) 
		when L =:= Label ->
		  NodeId = clean(XNodeId),
		  Confirm = #hex_signal {id = Id,
					 chan = Chan,
					 type = ?HEX_ALARM_CNFRM,
					 value = (NodeId bsl 8) bor Channel,
					 source = {event,Label}},
		  run_transmit(Confirm, State#state.transmit_rules),
		  [{NodeId, Channel} | Acc];
	     (_I, Acc) ->
		  Acc
	  end, [], Map) of
	[_I | _Rest] = _List ->
	    %% At least one item found
	    lager:debug("alarm_confirm sent for ~p", [_List]);
	[] ->
	    lager:warning("alarm confirm for unmapped item ~p",[Label])
    end.

run_alarm_confirm_ack(Signal=#hex_signal {id = Id, chan = Chan, value = Value}, 
	       State=#state {map = Map}) ->
    lager:debug("signal ~p", [Signal]),
    run_alarm_confirm_ack(cobid2nodeid(Id), Chan, Value, Map, State).

run_alarm_confirm_ack(Id, Chan, Alarm, 
	       [#map_item {label = Label, nodeid = Id, channel = Chan} | Map], 
	       State=#state{evt_list = EList, subs = Subs}) ->
    lager:debug("event ~p, alarm ~p", [Label, Alarm]),
    NewElist = event_alarm_confirm_ack(Label, Alarm, EList, [], Subs),
    run_alarm_confirm_ack(Id, Chan, Alarm, Map, State#state{evt_list = NewElist});
run_alarm_confirm_ack(Id, Chan, Alarm, [_MapItem | Map], State) ->
    run_alarm_confirm_ack(Id, Chan, Alarm, Map, State);
run_alarm_confirm_ack(_Id, _Chan, _Alarm, [], State) ->
    State.

event_alarm_confirm_ack(_Label, _Alarm, [], Acc, _Subs) ->
    Acc;
event_alarm_confirm_ack(Label, Alarm, 
	    [E=#int_event {label = Label, app = App, app_flags = AppFlags} | 
	     Events], 
	    Acc, Subs) ->
    App:output(AppFlags, [{alarm_ack, 0}]),
    Event = [{'event-type', 'alarm-ack'}, {label, Label}],
    inform_subscribers(Event, Subs),
    event_alarm_confirm_ack(Label, Alarm, Events, 
		[E#int_event {alarm = -1} | Acc], Subs);
event_alarm_confirm_ack(Label, Alarm, [E | Events], Acc, Subs) ->
    event_alarm_confirm_ack(Label, Alarm, Events, [E | Acc], Subs).

run_output_alarm(Signal=#hex_signal {id = Id, chan = Chan, value = Value}, 
	       State=#state {map = Map}) ->
    lager:debug("signal ~p", [Signal]),
    run_output_alarm(cobid2nodeid(Id), Chan, Value, Map, State).

run_output_alarm(Id, Chan, AlarmState, 
	       [#map_item {label = Label, nodeid = Id, channel = Chan} | Map], 
	       State=#state{evt_list = EList, subs = Subs}) ->
    lager:debug("event ~p, alarm state ~p", [Label, AlarmState]),
    NewElist = event_output_alarm(Label, AlarmState, EList, [], Subs),
    run_output_alarm(Id, Chan, AlarmState, Map, 
		    State#state{evt_list = NewElist});
run_output_alarm(Id, Chan, AlarmState, [_MapItem | Map], State) ->
    run_output_alarm(Id, Chan, AlarmState, Map, State);
run_output_alarm(_Id, _Chan, _AlarmState, [], State) ->
    State.

event_output_alarm(_Label, _AlarmState, [], Acc, _Subs) ->
    Acc;
event_output_alarm(Label, AlarmState, 
	    [E=#int_event {label = Label, app = App, app_flags = AppFlags} | 
	     Events], 
	    Acc, Subs) ->
    App:output(AppFlags, [{output_alarm, AlarmState}]),
    Event = [{'event-type', 'alarm-state'}, {label, Label}, 
	     {value, AlarmState}],
    inform_subscribers(Event, Subs),
    event_output_alarm(Label, AlarmState, Events, 
		[E#int_event {alarm = AlarmState} | Acc], Subs);
event_output_alarm(Label, AlarmState, [E | Events], Acc, Subs) ->
    event_output_alarm(Label, AlarmState, Events, [E | Acc], Subs).

inform_subscribers(_Msg, []) ->
    ok;
inform_subscribers(Msg, [#subscriber {pid = Pid, cb = CB, options=Opts} | Subs]) ->
    case match_subscriber(Msg, Opts) of
	true ->
	    case CB of
		{Module, Function} ->
		    lager:debug("calling ~p:~p(~p)", [Module, Function, Msg]),
		    Module:Function(Msg);
		undefined ->
		    lager:debug("informing ~p of ~p", [Pid, Msg]),
		    Pid ! Msg
	    end,
	    inform_subscribers(Msg, Subs);
	false ->
	    inform_subscribers(Msg, Subs)
    end.

match_subscriber(Options, MatchOptions) ->
    R = match_options(Options, MatchOptions),
    lager:debug("match ~p with ~p = ~p", [Options, MatchOptions, R]),
    R.

match_options([{Key,Value}|Ks], MatchOptions) ->
    case lists:keyfind(Key, 1, MatchOptions) of
	false -> match_options(Ks, MatchOptions);
        {_,MatchValue} ->
	    try lists:member(Value, MatchValue) of
		true ->
		    match_options(Ks, MatchOptions);
		false ->
		    false
	    catch
		error:_ ->
		    match_options(Ks, MatchOptions)
	    end
    end;
match_options([], _MatchOptions) ->
    true.
	
find_map_item([M=#map_item{label=Label,nodeid=Id,channel=Chan}|_Map],
	      Label,Id,Chan) ->
    {true,M};
find_map_item([_|Map],Label,Id,Chan) ->
    find_map_item(Map,Label,Id,Chan);
find_map_item([],_Label,_Id,_Chan) ->
    false.

%% Remove specific item
remove_mapped(_Label,_Id,_Chan,[],Acc) ->
    Acc;
remove_mapped(Label,Id,Chan, 
	      [#map_item{label=Label,nodeid=Id,channel=Chan}|Map],Acc) ->
    remove_mapped(Label,Id,Chan,Map,Acc);
remove_mapped(Label,Id,Chan,[MapItem|Map],Acc) ->
    remove_mapped(Label,Id,Chan,Map,[MapItem|Acc]).

%% Remove all items on node Id.
reset(_Id,[],State, NewMap) ->
    lager:debug("items on ~p removed", [_Id]),
    State#state{map = NewMap};
reset(Id, [#map_item{nodeid = Id, label = Label} | Map], 
      State=#state{evt_list = Events, subs = Subs}, Acc) ->
    NewEvents = 
	case lists:keytake(Label, #int_event.label, Events) of
	    {value, E=#int_event{}, Rest} ->
		clear_alarm(E, Subs),
		deactivate(E, Subs),
		[E#int_event{alarm = 0, 
			     analog_value = 0, 
			     state = 0, 
			     active = false} | Rest];
	    false ->
		lager:warning("Event ~p not found",[Label]),
		Events
	end,
    reset(Id, Map, State#state{evt_list = NewEvents}, Acc);
reset(Id, [MapItem|Map], State, Acc) ->
    reset(Id, Map, State, [MapItem|Acc]).

clear_alarm(#int_event{alarm = 0}, _Subs) ->
    ok;
clear_alarm(#int_event{label = Label}, Subs) ->
    Event = [{'event-type','alarm'},{label, Label}, {value, 0}],
    inform_subscribers(Event, Subs).

deactivate(#int_event{active = false}, _Subs) ->
    ok;
deactivate(#int_event{analog_value = AV, label = Label}, Subs) 
  when AV =/= 0->
    Event = [{'event-type','output-state'}, {label, Label}, {value, 0}],
    inform_subscribers(Event, Subs);
deactivate(#int_event{label = Label}, Subs) ->
    Event = [{'event-type','output-active'}, {label, Label}, {value, 0}],
    inform_subscribers(Event, Subs).

%% handle "distribution" messages when match
run_transmit(Signal, Rules) when is_record(Signal, hex_signal) ->
    run_transmit_(Signal, Rules).

run_transmit_(Signal, [Rule|Rules]) ->
    case match_pattern(Signal, <<>>, Rule#hex_transmit.signal) of
	{true,_Type,_Value} ->
	    lager:debug(" ~s pattern match", [format_signal(Signal)]),
	    App = Rule#hex_transmit.app,
	    App:transmit(Signal, Rule#hex_transmit.flags),
	    run_transmit_(Signal, Rules);
	false ->
	    run_transmit_(Signal, Rules)
    end;
run_transmit_(_Signal, []) ->
    ok.

value2nid(Value) ->
    Id0 = Value bsr 8,
    Id  = if Id0 < 127 -> Id0;
	      true -> Id0 bor ?HEX_COBID_EXT
	   end,
    Chan = (Value band 16#ff),
    {Id, Chan}.

clean(NodeId) ->
    %% When comparing signals
    NodeId band (?HEX_XNODE_ID_MASK bor ?HEX_COBID_EXT).
 
cobid2nodeid(Id) ->
    %% When dealing with #map_item.
    co_lib:cobid_to_nodeid(Id).
    %%NodeId band 16#ffffff.


match_pattern(Sig, Pat) ->
    match_pattern(Sig, <<>>, Pat).

match_pattern(Sig, _Data, Pat) when is_record(Sig, hex_signal),
				    is_record(Pat, hex_pattern) ->
     case match_value(Pat#hex_pattern.id,Sig#hex_signal.id) andalso
	match_value(Pat#hex_pattern.chan,Sig#hex_signal.chan) andalso
	match_value(Pat#hex_pattern.type, Sig#hex_signal.type) of
	true ->
	     lager:debug("match for signal ~s ", [format_signal(Sig)]),
	     case match_value(Pat#hex_pattern.value,Sig#hex_signal.value) of
		 true ->
		    lager:debug("match for value ~p ", [Sig#hex_signal.value]),
		    case Sig#hex_signal.type of
			?HEX_DIGITAL ->
			    {true, digital, Sig#hex_signal.value};
			?HEX_ANALOG ->
			    {true, analog, Sig#hex_signal.value};
			?HEX_ENCODER ->
			    {true, encoder, Sig#hex_signal.value};
			?HEX_RFID    ->
			    {true, rfid, Sig#hex_signal.value};
			Type         ->
			    {true, Type, Sig#hex_signal.value}
		    end;
		false -> false
	    end;
	false ->
	    false
    end;
match_pattern(Sig, Data, Pat) when is_record(Sig, hex_signal),
				   is_binary(Data),
				   is_record(Pat, hex_bin_pattern) ->
    case match_value(Pat#hex_bin_pattern.id, Sig#hex_signal.id) of
	true ->
	    R = match_bin_pattern(Data, Pat#hex_bin_pattern.bin, []),
	    lager:debug("match bin pattern ~p / ~p = ~p",
			[Data, Pat#hex_bin_pattern.bin, R]),
	    R;
	false ->
	    false
    end.

match_bin_pattern(Data, [{Size,Bind}|Pattern], Bound) when is_integer(Size) ->
    case Data of
	<<Bind:Size/little,Data1/bitstring>> when is_integer(Bind) ->
	    match_bin_pattern(Data1, Pattern, Bound);
	<<_:Size/little,Data1/bitstring>> when Bind =:= '_' ->  %% skip
	    match_bin_pattern(Data1, Pattern, Bound);
	<<Value:Size/little,Data1/bitstring>> when is_atom(Bind) ->
	    match_bin_pattern(Data1, Pattern, [{Size,Bind,Value}|Bound]);
	_ ->
	    false
    end;
match_bin_pattern(_Data, [], Bound) ->  %% fixme keep bound name in env!
    case lists:reverse(Bound) of
	[{1,_Name,Value}|_] ->
	    {true, digital, Value};
	[{_Size,_Name,Value}|_] ->
	    {true, analog, Value}
    end.

match_value(A, A) -> true;
match_value({mask,Mask,Match}, A) -> A band Mask =:= Match;
match_value({range,Low,High}, A) -> (A >= Low) andalso (A =< High);
match_value({'not',Cond}, A) -> not match_value(Cond,A);
match_value({'and',C1,C2}, A) -> match_value(C1,A) andalso match_value(C2,A);
match_value({'or',C1,C2}, A) -> match_value(C1,A) orelse match_value(C2,A);
match_value([Cond|Cs], A) -> match_value(Cond,A) andalso match_value(Cs, A);
match_value([], _A) -> true;
match_value(_, _) -> false.

input(I, Value) when ?is_label(I) ->
    lager:debug("input ~w ~w", [I, Value]),
    try ets:lookup(?TABLE, {input,I}) of
	[] ->
	    lager:warning("hex_input ~w not running", [I]),
	    ignore;
	[{_,Fsm}] ->
	    gen_fsm:send_event(Fsm, Value)
    catch
	error:badarg ->
	    lager:warning("hex_server not running", []),
	    ignore
    end.

output(Channel,Target,Value={_Type,_,_}) when
      is_atom(Target), is_integer(Channel), Channel >= 1, Channel =< 254 ->
    lager:debug("output ~w:~s ~w", [Channel,Target,Value]),
    try ets:lookup(?TABLE, {output,Channel}) of
	[] ->
	    lager:warning("output ~w not running", [Channel]),
	    ignore;
	[{_,Fsm}] ->
	    gen_fsm:send_event(Fsm, {Target,Value})
    catch
	error:badarg ->
	    lager:warning("hex_server not running", []),
	    ignore
    end.

input2outputs(Label, List) ->
    case lists:keyfind(Label, #hex_input.label, List) of
	#hex_input {flags = Flags} ->
	    case lists:keyfind(output, 1, Flags) of
		{output, Output} ->
		    Output;
		false ->
		    {error, no_output}
	    end;
	false ->
	    {error, unknown_input}
    end.

to_pid(Id, List) ->
    case lists:keyfind(Id, 1, List) of
	{Id, Pid} when is_pid(Pid) ->
	    Pid;
	false ->
	    {error, no_process}
    end.

transmit(Signal=#hex_signal{}, _Env) ->
    gen_server:cast(?SERVER, {transmit, Signal}).

event(S0=#hex_signal{}, Env) ->
    S = #hex_signal { id    = event_value(S0#hex_signal.id, Env),
		      chan  = event_value(S0#hex_signal.chan, Env),
		      type  = event_value(S0#hex_signal.type, Env),
		      value = event_value(S0#hex_signal.value, Env),
		      source = event_value(S0#hex_signal.source, Env)
		    },
    Data = proplists:get_value(data, Env, <<>>),
    gen_server:cast(?SERVER, {event, S, Data}).

event_value(Var, Env) when is_atom(Var) ->
    proplists:get_value(Var, Env, 0);
event_value(Value, _Env) ->
    Value.

format_signal(#hex_signal{id = I, chan = C, type = T, source = S, value = V}) ->
    io_lib_format:fwrite(
      "{Node ~.16.0#, Channel ~p, Index ~.16.0#, Source ~p, Value ~p}",
      [I,C,T,S,V]).

format_pattern(#hex_pattern{id = I, chan = C, type = T, value = V}) ->
    io_lib_format:fwrite(
      "{Id ~.16.0#, Channel ~p, Type ~.16.0#, Value ~p}",
      [I,C,T,V]).

dump_state(State) ->
    io:format("State\n:", []),
    io:format("Config ~p\n", [State#state.config]),
    io:format("NodeId ~p\n", [State#state.nodeid]),
    io:format("Table ~p\n", [State#state.tab]),
    io:format("OwnerTable ~p\n", [State#state.owner_table]),

    io:format("Out List\n", []),
    lists:foreach(
      fun({Label, Pid}) ->
	      io:format("~p ~p~n", [Label,Pid])
      end, State#state.out_list),

    io:format("In List\n", []),
    lists:foreach(
      fun({Label, Pid}) ->
	      io:format("~p ~p~n", [Label,Pid])
      end, State#state.in_list),

    io:format("Event List\n", []),
    lists:foreach(
      fun(E=#int_event{label = Label, signal = Signal}) ->
	      io:format("~p\n", [E]),
	      if not is_integer(Label) ->
		      io:format("     ~p\n", [Label]),
		      io:format("     ~s\n", [format_signal(Signal)]);
		 true ->
		      do_nothing
	      end
      end, State#state.evt_list),

    dump_map(State#state.map),

    io:format("Transmit Rules\n", []),
    lists:foreach(
      fun(T) ->
	      io:format("~p ~n", [T])
      end, State#state.transmit_rules),

    io:format("Input Rules\n", []),
    lists:foreach(
      fun(I) ->
	      io:format("~p ~n", [I])
      end, State#state.input_rules),

    io:format("Plugin up ~p\n", [State#state.plugin_up]),
    io:format("Plugin down ~p\n", [State#state.plugin_down]),
    io:format("Subscribers ~p\n", [State#state.subs]),
    io:format("Owners ~p\n", [State#state.owners]).

dump_map(Map) ->
    lists:foreach(
      fun(M) ->
	      io:format("~6.16.0B:~3w ~p~n", [M#map_item.nodeid,
					      M#map_item.channel,
					      M#map_item.label])
      end, lists:sort(fun(A, B) ->
			      An = A#map_item.nodeid,
			      Bn = B#map_item.nodeid,
			      if An < Bn -> true;
				 An =:= Bn ->
				      A#map_item.channel < B#map_item.channel;
				 true -> false
			      end
		      end, Map)).
