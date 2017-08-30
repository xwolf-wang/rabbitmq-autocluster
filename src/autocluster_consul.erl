%%==============================================================================
%% @author Gavin M. Roy <gavinr@aweber.com>
%% @copyright 2015-2016 AWeber Communications
%% @end
%%==============================================================================
-module(autocluster_consul).

-behavior(autocluster_backend).

%% autocluster_backend methods
-export([nodelist/0,
         lock/1,
         unlock/1,
         register/0,
         unregister/0]).

%% Useful for debugging
-export([service_address/0]).

%% Ignore this (is used so we can stub with meck in tests)
-export([build_registration_body/0]).

%% For timer based health checking
-export([send_health_check_pass/0, session_ttl_update_callback/1]).

%% Export all for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-include("autocluster.hrl").

-define(CREATE_SESSION_RETRIES, 10).


%%--------------------------------------------------------------------
%% @doc
%% Return a list of healthy nodes registered in Consul
%% @end
%%--------------------------------------------------------------------
-spec nodelist() -> {ok, [node()]}|{error, Reason :: string()}.
nodelist() ->
  case autocluster_httpc:get(autocluster_config:get(consul_scheme),
                             autocluster_config:get(consul_host),
                             autocluster_config:get(consul_port),
                             [v1, health, service,
                              autocluster_config:get(consul_svc)],
                             node_list_qargs()) of
    {ok, Nodes} ->
      {ok, extract_nodes(
             filter_nodes(Nodes,
                          autocluster_config:get(consul_include_nodes_with_warnings)))};
    Error       -> Error
  end.


%% @doc Tries to create a session.
%% if there is an Error 500 retries until ?CREATE_SESSION_RETRIES

-spec maybe_create_session(string(), pos_integer()) -> {ok,string()} | {error, string()}.
maybe_create_session(Who, N) when N > 0 ->
    case create_session(Who, autocluster_config:get(consul_svc_ttl)) of
        {error, "500"} -> 
	    autocluster_log:warning("Error 500 while creating a Consul session, " ++
					" ~p retries left", [N]),
	    timer:sleep(2000),
	    maybe_create_session(Who, N -1);
        Value -> Value
    end;
maybe_create_session(_Who, _N) ->
    lists:flatten(io_lib:format("Error while creating a Consul session,"++
				    "reason: too many 'Error 500' ", [])).



%% @doc Tries to acquire lock using a separately created session
%% If locking succeeds, starts periodic action to refresh TTL on
%% the session. Otherwise watches the key until lock existing lock is
%% released or too much time has passed.
%% @end.
-spec lock(string()) -> ok | {error, string()}.
lock(Who) ->
    case maybe_create_session(Who, ?CREATE_SESSION_RETRIES) of
        {ok, SessionId} ->
            start_session_ttl_updater(SessionId),
            Now = time_compat:erlang_system_time(seconds),
            EndTime = Now + autocluster_config:get(lock_wait_time),
            lock(SessionId, Now, EndTime);

        {error, Reason} ->
           lists:flatten(io_lib:format("Error while creating a Consul session, reason: ~p", [Reason]))
    end.


%% @doc Stops session TTL updater and releases lock in consul. 'ok' is
%% only returned when lock was successfully released (i.e. if the session
%% was not invalidated in the meantime)
%% We stop updating TTL only after we have successfully released the lock
%% @end
-spec unlock(term()) -> ok | {error, string()}.
unlock(SessionId) ->
    stop_session_ttl_updater(SessionId),
    case release_lock(SessionId) of
        {ok, true} ->
            ok;
        {ok, false} ->
            {error, lists:flatten(io_lib:format("Error while releasing the lock, session ~s may have been invalidated", [SessionId]))};
        {error, _} = Err ->
            Err
    end.


%%--------------------------------------------------------------------
%% @doc
%% Register with Consul as providing rabbitmq service
%% @end
%%--------------------------------------------------------------------
-spec register() -> ok | {error, Reason :: string()}.
register() ->
  case registration_body() of
    {ok, Body} ->
      case autocluster_httpc:post(autocluster_config:get(consul_scheme),
                                  autocluster_config:get(consul_host),
                                  autocluster_config:get(consul_port),
                                  [v1, agent, service, register],
                                  maybe_add_acl([]), Body) of
        {ok, _} ->
              case autocluster_config:get(consul_svc_ttl) of
                  undefined -> ok;
                  Interval ->
                      autocluster_periodic:start_delayed(autocluster_consul_node_key_updater, Interval * 500,
                                                         {?MODULE, send_health_check_pass, []}),
                      ok
              end;
        Error   -> autocluster_util:stringify_error(Error)
      end;
    Error -> Error
  end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Helpers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%
%% @doc
%% Tries to acquire lock. If the lock is held by someone else, waits until it
%% is released, or too much time has passed
%% @end
-spec lock(string(), pos_integer(), pos_integer()) -> {ok, string()} | {error, string()}.
lock(_, Now, EndTime) when EndTime < Now ->
    {error, "Acquiring lock taking too long, bailing out"};
lock(SessionId, _, EndTime) ->
    case acquire_lock(SessionId) of
        {ok, true} ->
            {ok, SessionId};
        {ok, false} ->
            case get_lock_status() of
                {ok, {SessionHeld, ModifyIndex}} ->
                    Wait = max(EndTime - time_compat:erlang_system_time(seconds), 0),
                    case wait_for_lock_release(SessionHeld, ModifyIndex, Wait) of
                        ok ->
                            lock(SessionId, time_compat:erlang_system_time(seconds), EndTime);
                        {error, Reason} ->
                            {error, lists:flatten(io_lib:format("Error waiting for lock release, reason: ~s",[Reason]))}
                    end;
                {error, Reason} ->
                    {error, lists:flatten(io_lib:format("Error obtaining lock status, reason: ~s", [Reason]))}
            end;
        {error, Reason} ->
            {error, lists:flatten(io_lib:format("Error while acquiring lock, reason: ~s", [Reason]))}
    end.


%%--------------------------------------------------------------------
%% @doc
%% Let Consul know that the health check should be passing
%% @end
%%--------------------------------------------------------------------
-spec send_health_check_pass() -> ok.
send_health_check_pass() ->
  Service = string:join(["service", service_id()], ":"),
  case autocluster_httpc:get(autocluster_config:get(consul_scheme),
                             autocluster_config:get(consul_host),
                             autocluster_config:get(consul_port),
                             [v1, agent, check, pass, Service],
                             maybe_add_acl([])) of
    {ok, []} -> ok;
    {error, "500"} ->
          maybe_re_register(wait_nodelist());
    {error, Reason} ->
          autocluster_log:error("Error updating Consul health check: ~p",
                                [Reason]),
      ok
  end.

maybe_re_register({error, Reason}) ->
    autocluster_log:error("Internal error in Consul while updating health check. "
                          "Cannot obtain list of nodes registered in Consul either: ~p",
                          [Reason]);
maybe_re_register({ok, Members}) ->
    case lists:member(node(), Members) of
        true ->
            autocluster_log:error("Internal error in Consul while updating health check",
                                  []);
        false ->
            autocluster_log:error("Internal error in Consul while updating health check, "
                                  "node is not registered. Re-registering", []),
            register()
    end.

wait_nodelist() ->
    wait_nodelist(60).

wait_nodelist(N) ->
    case {nodelist(), N} of
        {Reply, 0} ->
            Reply;
        {{ok, _} = Reply, _} ->
            Reply;
        {{error, _}, _} ->
            timer:sleep(1000),
            wait_nodelist(N - 1)
    end.

%%--------------------------------------------------------------------
%% @doc
%% Unregister the rabbitmq service for this node from Consul.
%% @end
%%--------------------------------------------------------------------
-spec unregister() -> ok | {error, Reason :: string()}.
unregister() ->
  Service = service_id(),
  case autocluster_httpc:get(autocluster_config:get(consul_scheme),
                             autocluster_config:get(consul_host),
                             autocluster_config:get(consul_port),
                             [v1, agent, service, deregister, Service],
                             maybe_add_acl([])) of
    {ok, _} -> ok;
    Error   -> Error
  end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% If configured, add the ACL token to the query arguments.
%% @end
%%--------------------------------------------------------------------
-spec maybe_add_acl(QArgs :: list()) -> list().
maybe_add_acl(QArgs) ->
  case autocluster_config:get(consul_acl_token) of
    "undefined" -> QArgs;
    ACL         -> lists:append(QArgs, [{token, ACL}])
  end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% If nodes with health checks with 'warning' status are accepted, perform
%% the filtering, only selecting those with 'warning' or 'passing' status
%% @end
%%--------------------------------------------------------------------
-spec filter_nodes(ConsulResult :: list(), AllowWarning :: atom()) -> list().
filter_nodes(Nodes, Warn) ->
  case Warn of
    true ->
      lists:filter(fun({struct, Node}) ->
                    Checks = proplists:get_value(<<"Checks">>, Node),
                    lists:all(fun({struct, Check}) ->
                      lists:member(proplists:get_value(<<"Status">>, Check),
                                   [<<"passing">>, <<"warning">>])
                              end,
                              Checks)
                   end,
                   Nodes);
    false -> Nodes
  end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Take the list fo data as returned from the call to Consul and
%% return it as a properly formatted list of rabbitmq cluster
%% identifier atoms.
%% @end
%%--------------------------------------------------------------------
-spec extract_nodes(ConsulResult :: list()) -> list().
extract_nodes(Data) -> extract_nodes(Data, []).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Take the list fo data as returned from the call to Consul and
%% return it as a properly formatted list of rabbitmq cluster
%% identifier atoms.
%% @end
%%--------------------------------------------------------------------
-spec extract_nodes(ConsulResult :: list(), Nodes :: list())
    -> list().
extract_nodes([], Nodes)    -> Nodes;
extract_nodes([{struct, H}|T], Nodes) ->
  {struct, Service} = proplists:get_value(<<"Service">>, H),
  Value = proplists:get_value(<<"Address">>, Service),
  NodeName = case autocluster_util:as_string(Value) of
    "" ->
      {struct, NodeData} = proplists:get_value(<<"Node">>, H),
      Node = proplists:get_value(<<"Node">>, NodeData),
      maybe_add_domain(autocluster_util:node_name(Node));
    Address ->
      autocluster_util:node_name(Address)
  end,
  extract_nodes(T, lists:merge(Nodes, [NodeName])).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the query argument list required to fetch the node list from
%% Consul.
%% @end
%%--------------------------------------------------------------------
-spec node_list_qargs() -> list().
node_list_qargs() ->
  maybe_add_acl(node_list_qargs(autocluster_config:get(cluster_name))).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the query argument list required to fetch the node list from
%% Consul, evaluating the configured cluster name and returning the
%% tag filter if it's set.
%% @end
%%--------------------------------------------------------------------
-spec node_list_qargs(ClusterName :: string()) -> list().
node_list_qargs(Cluster) ->
  ClusterTag = case Cluster of
    "undefined" -> [];
    _           -> [{tag, Cluster}]
  end,
  node_list_qargs(ClusterTag, autocluster_config:get(consul_include_nodes_with_warnings)).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the query argument list required to fetch the node list from
%% Consul. Unless nodes with health checks having 'warning' status are
%% permitted, select only those with 'passing' status. Otherwise return
%% all for further filtering
%% @end
%%--------------------------------------------------------------------
-spec node_list_qargs(Args :: list(), AllowWarn :: atom()) -> list().
node_list_qargs(Value, Warn) ->
    case Warn of
        true  -> Value;
        false -> [passing | Value]
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% JSON-encode and serialize registration body
%% @end
%%--------------------------------------------------------------------
-spec registration_body() -> {ok, Body :: binary()} | {error, atom()}.
registration_body() ->
  serialize_json_body(autocluster_consul:build_registration_body()).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Build the registration body.
%% @end
%%--------------------------------------------------------------------
-spec build_registration_body() -> list().
build_registration_body() ->
  Payload1 = registration_body_add_id(),
  Payload2 = registration_body_add_name(Payload1),
  Payload3 = registration_body_maybe_add_address(Payload2),
  Payload4 = registration_body_add_port(Payload3),
  Payload5 = registration_body_maybe_add_check(Payload4),
  registration_body_maybe_add_tag(Payload5).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add the service ID to the registration request payload.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_add_id() -> list().
registration_body_add_id() ->
  [{'ID', list_to_atom(service_id())}].


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add the service name to the registration request payload.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_add_name(Payload :: list()) -> list().
registration_body_add_name(Payload) ->
  Name = list_to_atom(autocluster_config:get(consul_svc)),
  lists:append(Payload, [{'Name', Name}]).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the configuration indicating that the service address should
%% be set, adding the service address to the registration payload if
%% it is set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_address(Payload :: list())
    -> list().
registration_body_maybe_add_address(Payload) ->
  registration_body_maybe_add_address(Payload, service_address()).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the return from service_address/0 to see if the service
%% address is set, adding it to the registration payload if so.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_address(Payload :: list(), string())
    -> list().
registration_body_maybe_add_address(Payload, "undefined") -> Payload;
registration_body_maybe_add_address(Payload, Address) ->
  lists:append(Payload, [{'Address', list_to_atom(Address)}]).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the configured value for the TTL indicating how often
%% RabbitMQ should let Consul know that it's alive, adding the Consul
%% Check definition if it is set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_check(Payload :: list()) -> list().
registration_body_maybe_add_check(Payload) ->
  TTL = autocluster_config:get(consul_svc_ttl),
  registration_body_maybe_add_check(Payload, TTL).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the configured value for the TTL indicating how often
%% RabbitMQ should let Consul know that it's alive, adding the Consul
%% Check definition if it is set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_check(Payload :: list(),
                                        TTL :: integer() | undefined)
    -> list().
registration_body_maybe_add_check(Payload, undefined) ->
    case registration_body_maybe_add_deregister([]) of
        [{'DeregisterCriticalServiceAfter', _}]->
            autocluster_log:warning("Can't use Consul Deregister After without " ++
            "using TTL. The parameter CONSUL_DEREGISTER_AFTER will be ignored"),
            Payload;

        _ -> Payload
    end;
registration_body_maybe_add_check(Payload, TTL) ->
    CheckItems = [{'Notes', list_to_atom(?CONSUL_CHECK_NOTES)},
        {'TTL', list_to_atom(service_ttl(TTL))}, {'Status', passing}],
    Check = [{'Check', registration_body_maybe_add_deregister(CheckItems)}],
    lists:append(Payload, Check).



%%--------------------------------------------------------------------
%% @private
%% @doc
%% Add the service port to the registration request payload.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_add_port(Payload :: list()) -> list().
registration_body_add_port(Payload) ->
  lists:append(Payload,
               [{'Port', autocluster_config:get(consul_svc_port)}]).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the configured value for the DeregisterCriticalServiceAfter.
%% Consul removes the node after the timeout (If it is set)
%% Check definition if it is set.
%%
%% @end
%%--------------------------------------------------------------------

registration_body_maybe_add_deregister(Payload) ->
    DeregisterAfter = autocluster_config:get(consul_deregister_after),
    registration_body_maybe_add_deregister(Payload, DeregisterAfter).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the configured value for the DeregisterCriticalServiceAfter.
%% Consul removes the node after the timeout (If it is set)
%% Check definition if it is set.
%% @end
%%--------------------------------------------------------------------


-spec registration_body_maybe_add_deregister(Payload :: list(),
    TTL :: integer() | undefined)
        -> list().
registration_body_maybe_add_deregister(Payload, undefined) -> Payload;
registration_body_maybe_add_deregister(Payload, DeregisterAfter) ->
    Deregister = {'DeregisterCriticalServiceAfter',
        list_to_atom(service_ttl(DeregisterAfter))},
    autocluster_log:debug("Consul will deregister the service after ~p seconds in critical state~n",
                          [DeregisterAfter]),
    Payload ++ [Deregister].
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the configured value for the Cluster name, adding it as a
%% tag if set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_tag(Payload :: list()) -> list().
registration_body_maybe_add_tag(Payload) ->
  Value = autocluster_config:get(cluster_name),
  registration_body_maybe_add_tag(Payload, Value).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the configured value for the Cluster name, adding it as a
%% tag if set.
%% @end
%%--------------------------------------------------------------------
-spec registration_body_maybe_add_tag(Payload :: list(),
                                      ClusterName :: string())
    -> list().
registration_body_maybe_add_tag(Payload, "undefined") -> Payload;
registration_body_maybe_add_tag(Payload, Cluster) ->
  lists:append(Payload, [{'Tags', [list_to_atom(Cluster)]}]).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Validate CONSUL_SVC_ADDR_NODENAME parameter
%% it can be used if CONSUL_SVC_ADDR_AUTO is true
%% @end
%%--------------------------------------------------------------------

-spec validate_addr_parameters(false | true, false | true) -> false | true.
validate_addr_parameters(false, true) ->
    autocluster_log:warning("The params CONSUL_SVC_ADDR_NODENAME" ++
				" can be used only if CONSUL_SVC_ADDR_AUTO is true." ++
				" CONSUL_SVC_ADDR_NODENAME value will be ignored."),
    false;
validate_addr_parameters(_, _) ->
    true.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Check the multiple ways service address can be configured and
%% return the proper value, if directly set or discovered.
%% @end
%%--------------------------------------------------------------------
-spec service_address() -> string().
service_address() ->
  validate_addr_parameters(autocluster_config:get(consul_svc_addr_auto),
      autocluster_config:get(consul_svc_addr_nodename)),
  service_address(autocluster_config:get(consul_svc_addr),
                  autocluster_config:get(consul_svc_addr_auto),
                  autocluster_config:get(consul_svc_addr_nic),
                  autocluster_config:get(consul_svc_addr_nodename)).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the configuration values for the service address and
%% return the proper value if any of them are configured. If addr_auto
%% is configured, return the hostname. If not, but the address was
%% statically configured, return that. If it was not statically
%% configured, see if the NIC/IP address discovery is configured.
%% @end
%%--------------------------------------------------------------------
-spec service_address(Static :: string(),
                      Auto :: boolean(),
                      AutoNIC :: string(),
                      FromNodename :: boolean()) -> string().
service_address(_, true, "undefined", FromNodename) ->
  autocluster_util:node_hostname(FromNodename);
service_address(Value, false, "undefined", _) ->
  Value;
service_address(_, false, NIC, _) ->
  {ok, Addr} = autocluster_util:nic_ipv4(NIC),
  Addr.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create the service ID, conditionally checking to see if the service
%% address is set and appending that to the service name if so.
%% @end
%%--------------------------------------------------------------------
-spec service_id() -> string().
service_id() ->
  service_id(autocluster_config:get(consul_svc),
             service_address()).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Evaluate the value of the service address and either return the
%% name by itself, or the service name and address together.
%% @end
%%--------------------------------------------------------------------
-spec service_id(Name :: string(), Address :: string()) -> string().
service_id(Service, "undefined") -> Service;
service_id(Service, Address) ->
  string:join([Service, Address], ":").


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Return the service ttl int value as a string, appending the unit
%% @end
%%--------------------------------------------------------------------
-spec service_ttl(TTL :: integer()) -> string().
service_ttl(Value) ->
  autocluster_util:as_string(Value) ++ "s".


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Append Consul domain if long names are in use
%% @end
%%--------------------------------------------------------------------
-spec maybe_add_domain(Domain :: atom()) -> atom().
maybe_add_domain(Value) ->
  case autocluster_config:get(consul_use_longname) of
      true ->
          list_to_atom(string:join([atom_to_list(Value),
                                    "node",
                                    autocluster_config:get(consul_domain)],
                                   "."));
      false -> Value
  end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Process the result of JSON encoding the request body payload,
%% returning the body as a binary() value or the error returned by
%% the JSON serialization library.
%% @end
%%--------------------------------------------------------------------
-spec serialize_json_body(term()) -> {ok, Payload :: binary()} | {error, atom()}.
serialize_json_body([]) -> {ok, []};
serialize_json_body(Payload) ->
    case rabbit_misc:json_encode(Payload) of
        {ok, Body} -> {ok, list_to_binary(Body)};
        {error, Reason} -> {error, Reason}
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Session operations
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Extract session ID from Consul response
%% @end
%%--------------------------------------------------------------------
-spec get_session_id(term()) -> string().
get_session_id({struct, [{_, ID} | _]}) -> binary:bin_to_list(ID).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create a session to be acquired for a common key
%% @end
%%--------------------------------------------------------------------
-spec create_session(string(), pos_integer()) -> {ok, string()} | {error, Reason::string()}.
create_session(Name, TTL) ->
    case consul_session_create(maybe_add_acl([]),
                               [{'Name', list_to_atom(Name)},
                                {'TTL', list_to_atom(service_ttl(TTL))}]) of
        {ok, Response} ->
            {ok, get_session_id(Response)};
        {error, _} = Err ->
            Err
    end.


%%--------------------------------------------------------------------
%% @doc
%% Renew an existing session
%% @end
%%--------------------------------------------------------------------
-spec session_ttl_update_callback(string()) -> string().
session_ttl_update_callback(SessionId) ->
    _ = consul_session_renew(SessionId, maybe_add_acl([])),
    SessionId.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Start periodically renewing an existing session ttl
%% @end
%%--------------------------------------------------------------------
-spec start_session_ttl_updater(string()) -> ok.
start_session_ttl_updater(SessionId) ->
    Interval = autocluster_config:get(consul_svc_ttl),
    autocluster_log:debug("Starting session renewal"),
    autocluster_periodic:start_delayed({autocluster_consul_session, SessionId},
                                       Interval * 500,
                                       {?MODULE, session_ttl_update_callback, [SessionId]}).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Stop renewing session ttl
%% @end
%%--------------------------------------------------------------------
-spec stop_session_ttl_updater(string()) -> ok.
stop_session_ttl_updater(SessionId) ->
    _ = autocluster_periodic:stop({autocluster_consul_session, SessionId}),
    autocluster_log:debug("Stopped session renewal"),
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Lock operations
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%--------------------------------------------------------------------
%% @private
%% @doc Part of consul path that allows us to distinguish different
%% cluster using the same consul cluster
%% @end
%%--------------------------------------------------------------------
-spec cluster_name_path_part() -> string().
cluster_name_path_part() ->
  case autocluster_config:get(cluster_name) of
      "undefined" -> "default";
      Value -> Value
  end.


%%--------------------------------------------------------------------
%% @private
%% @doc Return a list of path segments that are the base path for all
%% consul kv keys related to current cluster.
%% @end
%%--------------------------------------------------------------------
-spec base_path() -> [autocluster_httpc:path_component()].
base_path() ->
  [autocluster_config:get(consul_lock_prefix), cluster_name_path_part()].


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns consul path for startup lock
%% @end
%%--------------------------------------------------------------------
-spec startup_lock_path() -> [autocluster_httpc:path_component()].
startup_lock_path() ->
  base_path() ++ ["startup_lock"].


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Acquire session for a key
%% @end
%%--------------------------------------------------------------------
-spec acquire_lock(string()) -> {ok, term()} | {error, string()}.
acquire_lock(SessionId) ->
    consul_kv_write(startup_lock_path(), maybe_add_acl([{acquire, SessionId}]), []).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Release a previously acquired lock held by a given session
%% @end
%%--------------------------------------------------------------------
-spec release_lock(string()) -> {ok, term()} | {error, string()}.
release_lock(SessionId) ->
    consul_kv_write(startup_lock_path(), maybe_add_acl([{release, SessionId}]), []).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Get lock status
%% XXX: probably makes sense to wrap output in a record to be
%% more future-proof
%% @end
%%--------------------------------------------------------------------
-spec get_lock_status() -> {ok, term()} | {error, string()}.
get_lock_status() ->
    case consul_kv_read(startup_lock_path(), maybe_add_acl([])) of
        {ok, [{struct, KeyData} | _]} ->
            SessionHeld = proplists:get_value(<<"Session">>, KeyData) =/= undefined,
            ModifyIndex = proplists:get_value(<<"ModifyIndex">>, KeyData),
            {ok, {SessionHeld, ModifyIndex}};
        {error, _} = Err ->
            Err
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Wait for lock to be released if it has been acquired by another node
%% @end
%%--------------------------------------------------------------------
-spec wait_for_lock_release(atom(), pos_integer(), pos_integer()) -> ok | {error, string()}.
wait_for_lock_release(false, _, _) -> ok;
wait_for_lock_release(_, Index, Wait) ->
    case consul_kv_read(startup_lock_path(),
                        maybe_add_acl([{index, Index},
                                       {wait, service_ttl(Wait)}])) of
        {ok, _}          -> ok;
        {error, _} = Err -> Err
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Consul API wrappers
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Read KV store key value
%% @end
%%--------------------------------------------------------------------
-spec consul_kv_read(Path, Query) -> {ok, term()} | {error, string()} when
      Path :: [autocluster_httpc:path_component()],
      Query :: [autocluster_httpc:query_component()].
consul_kv_read(Path, Query) ->
    autocluster_httpc:get(autocluster_config:get(consul_scheme),
                          autocluster_config:get(consul_host),
                          autocluster_config:get(consul_port),
                          [v1, kv] ++ Path, Query).


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Write KV store key value
%% @end
%%--------------------------------------------------------------------
-spec consul_kv_write(Path, Query, Body) -> {ok, term()} | {error, string()} when
      Path :: [autocluster_httpc:path_component()],
      Query :: [autocluster_httpc:query_component()],
      Body :: term().
consul_kv_write(Path, Query, Body) ->
    case serialize_json_body(Body) of
        {ok, Serialized} ->
            autocluster_httpc:put(autocluster_config:get(consul_scheme),
                                  autocluster_config:get(consul_host),
                                  autocluster_config:get(consul_port),
                                  [v1, kv] ++ Path, Query, Serialized);
        {error, _} = Err ->
            Err
    end.


%%%--------------------------------------------------------------------
%%% @private
%%% @doc
%%% Delete key from KV store
%%% @end
%%%--------------------------------------------------------------------
%-spec consul_kv_delete(Path) -> ok | {error, string()} when
%      Path :: [autocluster_httpc:path_component()].
%consul_kv_delete(Path) ->
%            case autocluster_httpc:delete(autocluster_config:get(consul_scheme),
%                                  autocluster_config:get(consul_host),
%                                  autocluster_config:get(consul_port),
%                                  [v1, kv] ++ Path, [], []) of
%        {ok, true} -> ok;
%        {ok, false} -> {error, "Failed to delete key from Consul"};
%        {error, _} = Err ->
%            Err
%    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Create session
%% @end
%%--------------------------------------------------------------------
-spec consul_session_create(Query, Body) -> {ok, term()} | {error, Reason::string()} when
      Query :: [autocluster_httpc:query_component()],
      Body :: term().
consul_session_create(Query, Body) ->
      case serialize_json_body(Body) of
          {ok, Serialized} ->
              autocluster_httpc:put(autocluster_config:get(consul_scheme),
                                    autocluster_config:get(consul_host),
                                    autocluster_config:get(consul_port),
                                    [v1, session, create], Query, Serialized);
          {error, _} = Err ->
              Err
      end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Renew session TTL
%% @end
%%--------------------------------------------------------------------
-spec consul_session_renew(string(), [autocluster_httpc:query_component()]) -> {ok, term()} | {error, string()}.
consul_session_renew(SessionId, Query) ->
  autocluster_httpc:put(autocluster_config:get(consul_scheme),
                        autocluster_config:get(consul_host),
                        autocluster_config:get(consul_port),
                        [v1, session, renew, list_to_atom(SessionId)], Query, []).
