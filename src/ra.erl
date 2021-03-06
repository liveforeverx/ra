-module(ra).

-include("ra.hrl").

-export([
         start_local_cluster/3,
         send/2,
         send/3,
         send_and_await_consensus/2,
         send_and_await_consensus/3,
         send_and_notify/3,
         dirty_query/2,
         members/1,
         consistent_query/2,
         start_node/1,
         restart_node/1,
         stop_node/1,
         delete_node/1,
         add_node/2,
         remove_node/2,
         trigger_election/1,
         leave_and_terminate/1,
         leave_and_terminate/2
        ]).

-type ra_cmd_ret() :: ra_node_proc:ra_cmd_ret().

start_local_cluster(Num, Name, Machine) ->
    [Node1 | _] = Nodes = [{ra_node:name(Name, integer_to_list(N)), node()}
                           || N <- lists:seq(1, Num)],
    Conf0 = #{log_module => ra_log_memory,
              log_init_args => #{},
              initial_nodes => Nodes,
              machine => Machine},
    Res = [begin
               {ok, _Pid} = ra_node_proc:start_link(Conf0#{id => Id,
                                                           uid => atom_to_binary(element(1, Id), utf8)}),
               Id
           end || Id <- Nodes],
    ok = ra:trigger_election(Node1),
    Res.

%% Starts a ra node
-spec start_node(ra_node:ra_node_config()) -> ok.
start_node(Conf) ->
    {ok, _Pid} = ra_nodes_sup:start_node(Conf),
    ok.

-spec restart_node(ra_node:ra_node_config()) -> ok.
restart_node(Config) ->
    {ok, _Pid} = ra_nodes_sup:restart_node(Config),
    ok.

-spec stop_node(ra_node_id() | ra_uid()) -> ok.
stop_node(UId) when is_binary(UId) ->
    try ra_nodes_sup:stop_node(UId) of
        ok -> ok;
        {error, not_found} -> ok
    catch
        exit:noproc -> ok;
        % TODO: should not be possible unless we pass a node() around
        exit:{{nodedown, _}, _}  -> ok
    end;
stop_node(NodeId) ->
    stop_node(uid_from_nodeid(NodeId)).

-spec delete_node(ra_node_id()) -> ok.
delete_node(NodeId) ->
    UId = uid_from_nodeid(NodeId),
    {ok, DataDir} = application:get_env(ra, data_dir),
    ra_nodes_sup:delete_node(UId, DataDir).

-spec add_node(ra_node_id(), ra_node_id()) ->
    ra_cmd_ret().
add_node(ServerRef, NodeId) ->
    ra_node_proc:command(ServerRef, {'$ra_join', NodeId, after_log_append},
                         ?DEFAULT_TIMEOUT).

-spec remove_node(ra_node_id(), ra_node_id()) -> ra_cmd_ret().
remove_node(ServerRef, NodeId) ->
    ra_node_proc:command(ServerRef, {'$ra_leave', NodeId, after_log_append}, 2000).

-spec trigger_election(ra_node_id()) -> ok.
trigger_election(Id) ->
    ra_node_proc:trigger_election(Id).

% safe way to remove an active node from a cluster
leave_and_terminate(NodeId) ->
    leave_and_terminate(NodeId, NodeId).

-spec leave_and_terminate(ra_node_id(), ra_node_id()) ->
    ok | timeout | {error, no_proc}.
leave_and_terminate(ServerRef, NodeId) ->
    LeaveCmd = {'$ra_leave', NodeId, await_consensus},
    case ra_node_proc:command(ServerRef, LeaveCmd, ?DEFAULT_TIMEOUT) of
        {timeout, Who} ->
            ?ERR("request to ~p timed out trying to leave the cluster", [Who]),
            timeout;
        {error, no_proc} = Err ->
            Err;
        {ok, _, _} ->
            ?ERR("~p has left the building. terminating", [NodeId]),
            stop_node(NodeId)
    end.

-spec send(ra_node_id(), term()) -> ra_cmd_ret().
send(Ref, Data) ->
    send(Ref, Data, ?DEFAULT_TIMEOUT).

-spec send(ra_node_id(), term(), timeout()) -> ra_cmd_ret().
send(Ref, Data, Timeout) ->
    ra_node_proc:command(Ref, usr(Data, after_log_append), Timeout).

-spec send_and_await_consensus(ra_node_id(), term()) -> ra_cmd_ret().
send_and_await_consensus(Ref, Data) ->
    send_and_await_consensus(Ref, Data, ?DEFAULT_TIMEOUT).

-spec send_and_await_consensus(ra_node_id(), term(), timeout()) ->
    ra_cmd_ret().
send_and_await_consensus(Ref, Data, Timeout) ->
    ra_node_proc:command(Ref, usr(Data, await_consensus), Timeout).

-spec send_and_notify(ra_node_id(), term(), term()) -> ok.
send_and_notify(Ref, Data, Correlation) ->
    Cmd = usr(Data, {notify_on_consensus, Correlation, self()}),
    ra_node_proc:cast_command(Ref, Cmd).

-spec dirty_query(Node::ra_node_id(), QueryFun::fun((term()) -> term())) ->
    {ok, {ra_idxterm(), term()}, ra_node_id() | not_known}.
dirty_query(ServerRef, QueryFun) ->
    ra_node_proc:query(ServerRef, QueryFun, dirty).

-spec consistent_query(Node::ra_node_id(),
                       QueryFun::fun((term()) -> term())) ->
    {ok, {ra_idxterm(), term()}, ra_node_id() | not_known}.
consistent_query(Node, QueryFun) ->
    ra_node_proc:query(Node, QueryFun, consistent).

-spec members(ra_node_id()) -> ra_node_proc:ra_leader_call_ret([ra_node_id()]).
members(ServerRef) ->
    ra_node_proc:state_query(ServerRef, members).


usr(Data, Mode) ->
    {'$usr', Data, Mode}.

uid_from_nodeid(NodeId) ->
    Name = ra_lib:ra_node_id_to_local_name(NodeId),
    ra_directory:registered_name_from_node_name(Name).

