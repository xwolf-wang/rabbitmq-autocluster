-module(autocluster_aws_tests).

-include_lib("eunit/include/eunit.hrl").

-include("autocluster.hrl").

%%
maybe_add_tag_filters_test() ->
  autocluster_testing:reset(),
  Tags = [{"region", "us-west-2"}, {"service", "rabbitmq"}],
  Expecation = [{"Filter.2.Name", "tag:service"}, {"Filter.2.Value.1", "rabbitmq"},
                {"Filter.1.Name", "tag:region"}, {"Filter.1.Value.1", "us-west-2"}],
  Result = autocluster_aws:maybe_add_tag_filters(Tags, [], 1),
  ?assertEqual(Expecation, Result).


get_hostname_name_from_reservation_set_test_() ->
    {
      foreach,
      fun autocluster_testing:on_start/0,
      fun autocluster_testing:on_finish/1,
      [{"from private DNS",
        fun() ->
                Expectation = ["ip-10-0-16-31.eu-west-1.compute.internal",
                               "ip-10-0-16-29.eu-west-1.compute.internal"],
                ?assertEqual(Expectation,
                             autocluster_aws:get_hostname_name_from_reservation_set(
                               reservation_set(), []))
        end},
       {"from private IP",
        fun() ->
                os:putenv("AWS_USE_PRIVATE_IP", "true"),
                Expectation = ["10.0.16.31", "10.0.16.29"],
                ?assertEqual(Expectation,
                             autocluster_aws:get_hostname_name_from_reservation_set(
                               reservation_set(), []))
        end}]
    }.

reservation_set() ->
    [{"item", [{"reservationId","r-006cfdbf8d04c5f01"},
               {"ownerId","248536293561"},
               {"groupSet",[]},
               {"instancesSet",
                [{"item",
                  [{"instanceId","i-0c6d048641f09cad2"},
                   {"imageId","ami-ef4c7989"},
                   {"instanceState",
                    [{"code","16"},{"name","running"}]},
                   {"privateDnsName",
                    "ip-10-0-16-29.eu-west-1.compute.internal"},
                   {"dnsName",[]},
                   {"instanceType","c4.large"},
                   {"launchTime","2017-04-07T12:05:10"},
                   {"subnetId","subnet-61ff660"},
                   {"vpcId","vpc-4fe1562b"},
                   {"privateIpAddress","10.0.16.29"}]}]}]},
     {"item", [{"reservationId","r-006cfdbf8d04c5f01"},
               {"ownerId","248536293561"},
               {"groupSet",[]},
               {"instancesSet",
                [{"item",
                  [{"instanceId","i-1c6d048641f09cad2"},
                   {"imageId","ami-af4c7989"},
                   {"instanceState",
                    [{"code","16"},{"name","running"}]},
                   {"privateDnsName",
                    "ip-10-0-16-31.eu-west-1.compute.internal"},
                   {"dnsName",[]},
                   {"instanceType","c4.large"},
                   {"launchTime","2017-04-07T12:05:10"},
                   {"subnetId","subnet-61ff660"},
                   {"vpcId","vpc-4fe1562b"},
                   {"privateIpAddress","10.0.16.31"}]}]}]}].
