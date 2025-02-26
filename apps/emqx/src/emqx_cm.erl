%%-------------------------------------------------------------------
%% Copyright (c) 2017-2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% Channel Manager
-module(emqx_cm).

-behaviour(gen_server).

-include("emqx_cm.hrl").
-include("logger.hrl").
-include("types.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("stdlib/include/qlc.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-export([start_link/0]).

-export([
    register_channel/3,
    unregister_channel/1,
    insert_channel_info/3
]).

-export([
    get_chan_info/1,
    get_chan_info/2,
    set_chan_info/2
]).

-export([
    get_chan_stats/1,
    get_chan_stats/2,
    set_chan_stats/2
]).

-export([
    open_session/3,
    discard_session/1,
    discard_session/2,
    takeover_session_begin/1,
    takeover_session_end/1,
    kick_session/1,
    kick_session/2
]).

-export([
    lookup_channels/1,
    lookup_channels/2,
    lookup_client/1,
    pick_channel/1
]).

%% Test/debug interface
-export([
    all_channels/0,
    all_client_ids/0
]).

%% Client management
-export([
    all_channels_table/1,
    live_connection_table/1
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

%% Internal export
-export([
    stats_fun/0,
    clean_down/1,
    mark_channel_connected/1,
    mark_channel_disconnected/1,
    is_channel_connected/1,
    get_connected_client_count/0
]).

%% RPC targets
-export([
    takeover_session/2,
    takeover_finish/2,
    do_kick_session/3,
    do_get_chan_info/2,
    do_get_chan_stats/2,
    do_get_chann_conn_mod/2
]).

-export_type([
    channel_info/0,
    chan_pid/0
]).

-type chan_pid() :: pid().

-type channel_info() :: {
    _Chan :: {emqx_types:clientid(), pid()},
    _Info :: emqx_types:infos(),
    _Stats :: emqx_types:stats()
}.

-type takeover_state() :: {_ConnMod :: module(), _ChanPid :: pid()}.

-define(CHAN_STATS, [
    {?CHAN_TAB, 'channels.count', 'channels.max'},
    {?CHAN_TAB, 'sessions.count', 'sessions.max'},
    {?CHAN_CONN_TAB, 'connections.count', 'connections.max'},
    {?CHAN_LIVE_TAB, 'live_connections.count', 'live_connections.max'}
]).

%% Batch drain
-define(BATCH_SIZE, 100000).

%% Server name
-define(CM, ?MODULE).

-define(IS_CLIENTID(CLIENTID),
    (is_binary(CLIENTID) orelse (is_atom(CLIENTID) andalso CLIENTID =/= undefined))
).

%% linting overrides
-elvis([
    {elvis_style, invalid_dynamic_call, #{ignore => [emqx_cm]}},
    {elvis_style, god_modules, #{ignore => [emqx_cm]}}
]).

%% @doc Start the channel manager.
-spec start_link() -> startlink_ret().
start_link() ->
    gen_server:start_link({local, ?CM}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%% @doc Insert/Update the channel info and stats to emqx_channel table
-spec insert_channel_info(
    emqx_types:clientid(),
    emqx_types:infos(),
    emqx_types:stats()
) -> ok.
insert_channel_info(ClientId, Info, Stats) when ?IS_CLIENTID(ClientId) ->
    Chan = {ClientId, self()},
    true = ets:insert(?CHAN_INFO_TAB, {Chan, Info, Stats}),
    ?tp(debug, insert_channel_info, #{clientid => ClientId}),
    ok.

%% @private
%% @doc Register a channel with pid and conn_mod.
%%
%% There is a Race-Condition on one node or cluster when many connections
%% login to Broker with the same clientid. We should register it and save
%% the conn_mod first for taking up the clientid access right.
%%
%% Note that: It should be called on a lock transaction
register_channel(ClientId, ChanPid, #{conn_mod := ConnMod}) when
    is_pid(ChanPid) andalso ?IS_CLIENTID(ClientId)
->
    Chan = {ClientId, ChanPid},
    %% cast (for process monitor) before inserting ets tables
    cast({registered, Chan}),
    true = ets:insert(?CHAN_TAB, Chan),
    true = ets:insert(?CHAN_CONN_TAB, {Chan, ConnMod}),
    ok = emqx_cm_registry:register_channel(Chan),
    mark_channel_connected(ChanPid),
    ok.

%% @doc Unregister a channel.
-spec unregister_channel(emqx_types:clientid()) -> ok.
unregister_channel(ClientId) when ?IS_CLIENTID(ClientId) ->
    true = do_unregister_channel({ClientId, self()}),
    ok.

%% @private
do_unregister_channel({_ClientId, ChanPid} = Chan) ->
    ok = emqx_cm_registry:unregister_channel(Chan),
    true = ets:delete(?CHAN_CONN_TAB, Chan),
    true = ets:delete(?CHAN_INFO_TAB, Chan),
    ets:delete_object(?CHAN_TAB, Chan),
    ok = emqx_hooks:run('cm.channel.unregistered', [ChanPid]),
    true.

%% @doc Get info of a channel.
-spec get_chan_info(emqx_types:clientid()) -> option(emqx_types:infos()).
get_chan_info(ClientId) ->
    with_channel(ClientId, fun(ChanPid) -> get_chan_info(ClientId, ChanPid) end).

-spec do_get_chan_info(emqx_types:clientid(), chan_pid()) ->
    option(emqx_types:infos()).
do_get_chan_info(ClientId, ChanPid) ->
    Chan = {ClientId, ChanPid},
    try
        ets:lookup_element(?CHAN_INFO_TAB, Chan, 2)
    catch
        error:badarg -> undefined
    end.

-spec get_chan_info(emqx_types:clientid(), chan_pid()) ->
    option(emqx_types:infos()).
get_chan_info(ClientId, ChanPid) ->
    wrap_rpc(emqx_cm_proto_v2:get_chan_info(ClientId, ChanPid)).

%% @doc Update infos of the channel.
-spec set_chan_info(emqx_types:clientid(), emqx_types:attrs()) -> boolean().
set_chan_info(ClientId, Info) when ?IS_CLIENTID(ClientId) ->
    Chan = {ClientId, self()},
    try
        ets:update_element(?CHAN_INFO_TAB, Chan, {2, Info})
    catch
        error:badarg -> false
    end.

%% @doc Get channel's stats.
-spec get_chan_stats(emqx_types:clientid()) -> option(emqx_types:stats()).
get_chan_stats(ClientId) ->
    with_channel(ClientId, fun(ChanPid) -> get_chan_stats(ClientId, ChanPid) end).

-spec do_get_chan_stats(emqx_types:clientid(), chan_pid()) ->
    option(emqx_types:stats()).
do_get_chan_stats(ClientId, ChanPid) ->
    Chan = {ClientId, ChanPid},
    try
        ets:lookup_element(?CHAN_INFO_TAB, Chan, 3)
    catch
        error:badarg -> undefined
    end.

-spec get_chan_stats(emqx_types:clientid(), chan_pid()) ->
    option(emqx_types:stats()).
get_chan_stats(ClientId, ChanPid) ->
    wrap_rpc(emqx_cm_proto_v2:get_chan_stats(ClientId, ChanPid)).

%% @doc Set channel's stats.
-spec set_chan_stats(emqx_types:clientid(), emqx_types:stats()) -> boolean().
set_chan_stats(ClientId, Stats) when ?IS_CLIENTID(ClientId) ->
    set_chan_stats(ClientId, self(), Stats).

-spec set_chan_stats(emqx_types:clientid(), chan_pid(), emqx_types:stats()) ->
    boolean().
set_chan_stats(ClientId, ChanPid, Stats) when ?IS_CLIENTID(ClientId) ->
    Chan = {ClientId, ChanPid},
    try
        ets:update_element(?CHAN_INFO_TAB, Chan, {3, Stats})
    catch
        error:badarg -> false
    end.

%% @doc Open a session.
-spec open_session(_CleanStart :: boolean(), emqx_types:clientinfo(), emqx_types:conninfo()) ->
    {ok, #{
        session := emqx_session:t(),
        present := boolean(),
        replay => _ReplayContext
    }}
    | {error, Reason :: term()}.
open_session(_CleanStart = true, ClientInfo = #{clientid := ClientId}, ConnInfo) ->
    Self = self(),
    emqx_cm_locker:trans(ClientId, fun(_) ->
        ok = discard_session(ClientId),
        ok = emqx_session:destroy(ClientInfo, ConnInfo),
        create_register_session(ClientInfo, ConnInfo, Self)
    end);
open_session(_CleanStart = false, ClientInfo = #{clientid := ClientId}, ConnInfo) ->
    Self = self(),
    emqx_cm_locker:trans(ClientId, fun(_) ->
        case emqx_session:open(ClientInfo, ConnInfo) of
            {true, Session, ReplayContext} ->
                ok = register_channel(ClientId, Self, ConnInfo),
                {ok, #{session => Session, present => true, replay => ReplayContext}};
            {false, Session} ->
                ok = register_channel(ClientId, Self, ConnInfo),
                {ok, #{session => Session, present => false}}
        end
    end).

create_register_session(ClientInfo = #{clientid := ClientId}, ConnInfo, ChanPid) ->
    Session = emqx_session:create(ClientInfo, ConnInfo),
    ok = register_channel(ClientId, ChanPid, ConnInfo),
    {ok, #{session => Session, present => false}}.

%% @doc Try to takeover a session from existing channel.
-spec takeover_session_begin(emqx_types:clientid()) ->
    {ok, emqx_session_mem:session(), takeover_state()} | none.
takeover_session_begin(ClientId) ->
    takeover_session_begin(ClientId, pick_channel(ClientId)).

takeover_session_begin(ClientId, ChanPid) when is_pid(ChanPid) ->
    case takeover_session(ClientId, ChanPid) of
        {living, ConnMod, ChanPid, Session} ->
            {ok, Session, {ConnMod, ChanPid}};
        _ ->
            none
    end;
takeover_session_begin(_ClientId, undefined) ->
    none.

%% @doc Conclude the session takeover process.
-spec takeover_session_end(takeover_state()) ->
    {ok, _ReplayContext} | {error, _Reason}.
takeover_session_end({ConnMod, ChanPid}) ->
    case wrap_rpc(emqx_cm_proto_v2:takeover_finish(ConnMod, ChanPid)) of
        {ok, Pendings} ->
            {ok, Pendings};
        {error, _} = Error ->
            Error
    end.

-spec pick_channel(emqx_types:clientid()) ->
    option(pid()).
pick_channel(ClientId) ->
    case lookup_channels(ClientId) of
        [] ->
            undefined;
        [ChanPid] ->
            ChanPid;
        ChanPids ->
            [ChanPid | StalePids] = lists:reverse(ChanPids),
            ?SLOG(warning, #{msg => "more_than_one_channel_found", chan_pids => ChanPids}),
            lists:foreach(
                fun(StalePid) ->
                    catch discard_session(ClientId, StalePid)
                end,
                StalePids
            ),
            ChanPid
    end.

takeover_finish(ConnMod, ChanPid) ->
    request_stepdown(
        {takeover, 'end'},
        ConnMod,
        ChanPid
    ).

%% @doc RPC Target @ emqx_cm_proto_v2:takeover_session/2
takeover_session(ClientId, Pid) ->
    try
        do_takeover_begin(ClientId, Pid)
    catch
        _:R when
            R == noproc;
            R == timeout;
            %% request_stepdown/3
            R == unexpected_exception
        ->
            none;
        % rpc_call/3
        _:{'EXIT', {noproc, _}} ->
            none
    end.

do_takeover_begin(ClientId, ChanPid) when node(ChanPid) == node() ->
    case do_get_chann_conn_mod(ClientId, ChanPid) of
        undefined ->
            none;
        ConnMod when is_atom(ConnMod) ->
            case request_stepdown({takeover, 'begin'}, ConnMod, ChanPid) of
                {ok, Session} ->
                    {living, ConnMod, ChanPid, Session};
                {error, Reason} ->
                    error(Reason)
            end
    end;
do_takeover_begin(ClientId, ChanPid) ->
    case wrap_rpc(emqx_cm_proto_v2:takeover_session(ClientId, ChanPid)) of
        %% NOTE: v5.3.0
        {living, ConnMod, Session} ->
            {living, ConnMod, ChanPid, Session};
        %% NOTE: other versions
        Res ->
            Res
    end.

%% @doc Discard all the sessions identified by the ClientId.
-spec discard_session(emqx_types:clientid()) -> ok.
discard_session(ClientId) when is_binary(ClientId) ->
    case lookup_channels(ClientId) of
        [] -> ok;
        ChanPids -> lists:foreach(fun(Pid) -> discard_session(ClientId, Pid) end, ChanPids)
    end.

%% @private Kick a local stale session to force it step down.
%% If failed to kick (e.g. timeout) force a kill.
%% Keeping the stale pid around, or returning error or raise an exception
%% benefits nobody.
-spec request_stepdown(Action, module(), pid()) ->
    ok
    | {ok, emqx_session:t() | _ReplayContext}
    | {error, term()}
when
    Action :: kick | discard | {takeover, 'begin'} | {takeover, 'end'}.
request_stepdown(Action, ConnMod, Pid) ->
    Timeout =
        case Action == kick orelse Action == discard of
            true -> ?T_KICK;
            _ -> ?T_TAKEOVER
        end,
    Return =
        %% this is essentially a gen_server:call implemented in emqx_connection
        %% and emqx_ws_connection.
        %% the handle_call is implemented in emqx_channel
        try apply(ConnMod, call, [Pid, Action, Timeout]) of
            ok -> ok;
            Reply -> {ok, Reply}
        catch
            % emqx_ws_connection: call
            _:noproc ->
                ok = ?tp(debug, "session_already_gone", #{stale_pid => Pid, action => Action}),
                {error, noproc};
            % emqx_connection: gen_server:call
            _:{noproc, _} ->
                ok = ?tp(debug, "session_already_gone", #{stale_pid => Pid, action => Action}),
                {error, noproc};
            _:{shutdown, _} ->
                ok = ?tp(debug, "session_already_shutdown", #{stale_pid => Pid, action => Action}),
                {error, noproc};
            _:{{shutdown, _}, _} ->
                ok = ?tp(debug, "session_already_shutdown", #{stale_pid => Pid, action => Action}),
                {error, noproc};
            _:{timeout, {gen_server, call, _}} ->
                ?tp(
                    warning,
                    "session_stepdown_request_timeout",
                    #{stale_pid => Pid, action => Action, stale_channel => stale_channel_info(Pid)}
                ),
                ok = force_kill(Pid),
                {error, timeout};
            _:Error:St ->
                ?tp(
                    error,
                    "session_stepdown_request_exception",
                    #{
                        stale_pid => Pid,
                        action => Action,
                        reason => Error,
                        stacktrace => St,
                        stale_channel => stale_channel_info(Pid)
                    }
                ),
                ok = force_kill(Pid),
                {error, unexpected_exception}
        end,
    case Action == kick orelse Action == discard of
        true -> ok;
        _ -> Return
    end.

force_kill(Pid) ->
    exit(Pid, kill),
    ok.

stale_channel_info(Pid) ->
    process_info(Pid, [status, message_queue_len, current_stacktrace]).

discard_session(ClientId, ChanPid) ->
    kick_session(discard, ClientId, ChanPid).

kick_session(ClientId, ChanPid) ->
    kick_session(kick, ClientId, ChanPid).

%% @doc RPC Target @ emqx_cm_proto_v2:kick_session/3
-spec do_kick_session(kick | discard, emqx_types:clientid(), chan_pid()) -> ok.
do_kick_session(Action, ClientId, ChanPid) when node(ChanPid) =:= node() ->
    case do_get_chann_conn_mod(ClientId, ChanPid) of
        undefined ->
            %% already deregistered
            ok;
        ConnMod when is_atom(ConnMod) ->
            ok = request_stepdown(Action, ConnMod, ChanPid)
    end.

%% @private This function is shared for session 'kick' and 'discard' (as the first arg Action).
kick_session(Action, ClientId, ChanPid) ->
    try
        wrap_rpc(emqx_cm_proto_v2:kick_session(Action, ClientId, ChanPid))
    catch
        Error:Reason ->
            %% This should mostly be RPC failures.
            %% However, if the node is still running the old version
            %% code (prior to emqx app 4.3.10) some of the RPC handler
            %% exceptions may get propagated to a new version node
            ?SLOG(
                error,
                #{
                    msg => "failed_to_kick_session_on_remote_node",
                    node => node(ChanPid),
                    action => Action,
                    error => Error,
                    reason => Reason
                },
                #{clientid => ClientId}
            )
    end.

kick_session(ClientId) ->
    case lookup_channels(ClientId) of
        [] ->
            ?SLOG(
                warning,
                #{msg => "kicked_an_unknown_session"},
                #{clientid => ClientId}
            ),
            ok;
        ChanPids ->
            case length(ChanPids) > 1 of
                true ->
                    ?SLOG(
                        warning,
                        #{
                            msg => "more_than_one_channel_found",
                            chan_pids => ChanPids
                        },
                        #{clientid => ClientId}
                    );
                false ->
                    ok
            end,
            lists:foreach(fun(Pid) -> kick_session(ClientId, Pid) end, ChanPids)
    end.

%% @doc Is clean start?
% is_clean_start(#{clean_start := false}) -> false;
% is_clean_start(_Attrs) -> true.

with_channel(ClientId, Fun) ->
    case lookup_channels(ClientId) of
        [] -> undefined;
        [Pid] -> Fun(Pid);
        Pids -> Fun(lists:last(Pids))
    end.

%% @doc Get all registered channel pids. Debug/test interface
all_channels() ->
    Pat = [{{'_', '$1'}, [], ['$1']}],
    ets:select(?CHAN_TAB, Pat).

%% @doc Get clientinfo for all clients
all_channels_table(ConnModuleList) ->
    Ms = ets:fun2ms(
        fun({{ClientId, _ChanPid}, Info, _Stats}) ->
            {ClientId, Info}
        end
    ),
    Table = ets:table(?CHAN_INFO_TAB, [{traverse, {select, Ms}}]),
    ConnModules = sets:from_list(ConnModuleList, [{version, 2}]),
    qlc:q([
        {ClientId, ConnState, ConnInfo, ClientInfo}
     || {ClientId, #{
            conn_state := ConnState,
            clientinfo := ClientInfo,
            conninfo := #{conn_mod := ConnModule} = ConnInfo
        }} <-
            Table,
        sets:is_element(ConnModule, ConnModules)
    ]).

%% @doc Get all local connection query handle
live_connection_table(ConnModules) ->
    Ms = lists:map(fun live_connection_ms/1, ConnModules),
    Table = ets:table(?CHAN_CONN_TAB, [{traverse, {select, Ms}}]),
    qlc:q([{ClientId, ChanPid} || {ClientId, ChanPid} <- Table, is_channel_connected(ChanPid)]).

live_connection_ms(ConnModule) ->
    {{{'$1', '$2'}, ConnModule}, [], [{{'$1', '$2'}}]}.

is_channel_connected(ChanPid) when node(ChanPid) =:= node() ->
    ets:member(?CHAN_LIVE_TAB, ChanPid);
is_channel_connected(_ChanPid) ->
    false.

%% @doc Get all registered clientIDs. Debug/test interface
all_client_ids() ->
    Pat = [{{'$1', '_'}, [], ['$1']}],
    ets:select(?CHAN_TAB, Pat).

%% @doc Lookup channels.
-spec lookup_channels(emqx_types:clientid()) -> list(chan_pid()).
lookup_channels(ClientId) ->
    lookup_channels(global, ClientId).

%% @doc Lookup local or global channels.
-spec lookup_channels(local | global, emqx_types:clientid()) -> list(chan_pid()).
lookup_channels(global, ClientId) ->
    case emqx_cm_registry:is_enabled() of
        true ->
            emqx_cm_registry:lookup_channels(ClientId);
        false ->
            lookup_channels(local, ClientId)
    end;
lookup_channels(local, ClientId) ->
    [ChanPid || {_, ChanPid} <- ets:lookup(?CHAN_TAB, ClientId)].

-spec lookup_client({clientid, emqx_types:clientid()} | {username, emqx_types:username()}) ->
    [channel_info()].
lookup_client({username, Username}) ->
    MatchSpec = [
        {{'_', #{clientinfo => #{username => '$1'}}, '_'}, [{'=:=', '$1', Username}], ['$_']}
    ],
    ets:select(?CHAN_INFO_TAB, MatchSpec);
lookup_client({clientid, ClientId}) ->
    [
        Rec
     || Key <- ets:lookup(?CHAN_TAB, ClientId),
        Rec <- ets:lookup(?CHAN_INFO_TAB, Key)
    ].

%% @private
wrap_rpc(Result) ->
    case Result of
        {badrpc, Reason} ->
            %% since emqx app 4.3.10, the 'kick' and 'discard' calls handler
            %% should catch all exceptions and always return 'ok'.
            %% This leaves 'badrpc' only possible when there is problem
            %% calling the remote node.
            error({badrpc, Reason});
        Res ->
            Res
    end.

%% @private
cast(Msg) -> gen_server:cast(?CM, Msg).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init([]) ->
    TabOpts = [public, {write_concurrency, true}],
    ok = emqx_utils_ets:new(?CHAN_TAB, [bag, {read_concurrency, true} | TabOpts]),
    ok = emqx_utils_ets:new(?CHAN_CONN_TAB, [bag | TabOpts]),
    ok = emqx_utils_ets:new(?CHAN_INFO_TAB, [ordered_set, compressed | TabOpts]),
    ok = emqx_utils_ets:new(?CHAN_LIVE_TAB, [ordered_set, {write_concurrency, true} | TabOpts]),
    ok = emqx_stats:update_interval(chan_stats, fun ?MODULE:stats_fun/0),
    State = #{chan_pmon => emqx_pmon:new()},
    {ok, State}.

handle_call(Req, _From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", call => Req}),
    {reply, ignored, State}.

handle_cast({registered, {ClientId, ChanPid}}, State = #{chan_pmon := PMon}) ->
    PMon1 = emqx_pmon:monitor(ChanPid, ClientId, PMon),
    {noreply, State#{chan_pmon := PMon1}};
handle_cast(Msg, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", cast => Msg}),
    {noreply, State}.

handle_info({'DOWN', _MRef, process, Pid, _Reason}, State = #{chan_pmon := PMon}) ->
    ?tp(emqx_cm_process_down, #{stale_pid => Pid, reason => _Reason}),
    BatchSize = emqx:get_config([node, channel_cleanup_batch_size], ?BATCH_SIZE),
    ChanPids = [Pid | emqx_utils:drain_down(BatchSize)],
    {Items, PMon1} = emqx_pmon:erase_all(ChanPids, PMon),
    lists:foreach(fun mark_channel_disconnected/1, ChanPids),
    ok = emqx_pool:async_submit_to_pool(
        ?CM_POOL,
        fun lists:foreach/2,
        [fun ?MODULE:clean_down/1, Items]
    ),
    {noreply, State#{chan_pmon := PMon1}};
handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),

    {noreply, State}.

terminate(_Reason, _State) ->
    emqx_stats:cancel_update(chan_stats).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

clean_down({ChanPid, ClientId}) ->
    try
        do_unregister_channel({ClientId, ChanPid})
    catch
        error:badarg -> ok
    end,
    ok = ?tp(debug, emqx_cm_clean_down, #{client_id => ClientId}).

stats_fun() ->
    lists:foreach(fun update_stats/1, ?CHAN_STATS).

update_stats({Tab, Stat, MaxStat}) ->
    case ets:info(Tab, size) of
        undefined -> ok;
        Size -> emqx_stats:setstat(Stat, MaxStat, Size)
    end.

-spec do_get_chann_conn_mod(emqx_types:clientid(), chan_pid()) ->
    module() | undefined.
do_get_chann_conn_mod(ClientId, ChanPid) ->
    Chan = {ClientId, ChanPid},
    try
        [ConnMod] = ets:lookup_element(?CHAN_CONN_TAB, Chan, 2),
        ConnMod
    catch
        error:badarg -> undefined
    end.

mark_channel_connected(ChanPid) ->
    ?tp(emqx_cm_connected_client_count_inc, #{chan_pid => ChanPid}),
    ets:insert_new(?CHAN_LIVE_TAB, {ChanPid, true}),
    ok.

mark_channel_disconnected(ChanPid) ->
    ?tp(emqx_cm_connected_client_count_dec, #{chan_pid => ChanPid}),
    ets:delete(?CHAN_LIVE_TAB, ChanPid),
    ?tp(emqx_cm_connected_client_count_dec_done, #{chan_pid => ChanPid}),
    ok.

get_connected_client_count() ->
    case ets:info(?CHAN_LIVE_TAB, size) of
        undefined -> 0;
        Size -> Size
    end.
