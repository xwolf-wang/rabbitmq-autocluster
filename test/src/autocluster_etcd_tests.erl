-module(autocluster_etcd_tests).

-include_lib("eunit/include/eunit.hrl").

-include("autocluster.hrl").


extract_nodes_test() ->
  Values =  #{<<"action">> => <<"get">>,<<"node">> => #{<<"createdIndex">> => 4,<<"dir">> => true,<<"key">> => <<"/rabbitmq/default/nodes">>,<<"modifiedIndex">> => 4,<<"nodes">> => [#{<<"createdIndex">> => 4,<<"expiration">> => <<"2017-06-06T13:24:49.430945264Z">>,<<"key">> => <<"/rabbitmq/default/nodes/rabbit@172.17.0.7">>,<<"modifiedIndex">> => 4,<<"ttl">> => 24,<<"value">> => <<"enabled">>},#{<<"createdIndex">> => 7,<<"expiration">> => <<"2017-06-06T13:24:51.846531249Z">>,<<"key">> => <<"/rabbitmq/default/nodes/rabbit@172.17.0.5">>,<<"modifiedIndex">> => 7,<<"ttl">> => 26,<<"value">> => <<"enabled">>}]}},
  Expectation = ['rabbit@172.17.0.7', 'rabbit@172.17.0.5'],
  ?assertEqual(Expectation, autocluster_etcd:extract_nodes(Values)).

base_path_test() ->
  autocluster_testing:reset(),
  ?assertEqual([v2, keys, "rabbitmq", "default"], autocluster_etcd:base_path()).

get_node_from_key_test() ->
  ?assertEqual('rabbit@foo', autocluster_etcd:get_node_from_key(<<"rabbitmq/default/nodes/foo">>)).

get_node_from_key_leading_slash_test() ->
  ?assertEqual('rabbit@foo', autocluster_etcd:get_node_from_key(<<"/rabbitmq/default/nodes/foo">>)).


node_path_test() ->
  autocluster_testing:reset(),
  Expectation = [v2, keys, "rabbitmq", "default", nodes, atom_to_list(node())],
  ?assertEqual(Expectation, autocluster_etcd:node_path()).

nodelist_without_existing_directory_test_() ->
  EtcdNodesResponse = [{<<"action">>,<<"get">>},
                               {<<"node">>,
                                   [{<<"key">>,<<"/rabbitmq/default">>},
                                         {<<"dir">>,true},
                                         {<<"nodes">>,
                                          [[{<<"key">>,<<"/rabbitmq/default/docker-autocluster-4">>},
                                                    {<<"value">>,<<"enabled">>},
                                                    {<<"expiration">>, <<"2016-07-04T12:47:17.245647965Z">>},
                                                    {<<"ttl">>,23},
                                                    {<<"modifiedIndex">>,3976},
                                                    {<<"createdIndex">>,3976}]]}]}],
  autocluster_testing:with_mock(
    [autocluster_httpc],
    [{"etcd backend creates directory when it's missing",
      fun () ->
          meck:sequence(autocluster_httpc, get, 5, [{error, "404"}, EtcdNodesResponse]),
          meck:expect(autocluster_httpc, put, fun (_, _, _, _, _, _) -> {ok, ok} end),
          autocluster_etcd:nodelist(),
          ?assert(meck:validate(autocluster_httpc))
      end}]).
