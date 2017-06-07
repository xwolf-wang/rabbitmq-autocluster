PROJECT = rabbitmq_autocluster
PROJECT_DESCRIPTION = Forms RabbitMQ clusters using a variety of backends (AWS EC2, DNS, Consul, Kubernetes, etc)
PROJECT_MOD = rabbitmq_autocluster_app
PROJECT_REGISTERED = autocluster_app autocluster_sup autocluster_cleanup

define PROJECT_APP_EXTRA_KEYS
	{broker_version_requirements, []}
endef

DEPS = rabbit rabbit_common  rabbitmq_aws

TEST_DEPS += rabbit erlsh rabbitmq_ct_helpers meck
dep_ct_helper = git https://github.com/extend/ct_helper.git master

IGNORE_DEPS += rabbitmq_java_client

DEP_EARLY_PLUGINS = rabbit_common/mk/rabbitmq-early-plugin.mk
DEP_PLUGINS = rabbit_common/mk/rabbitmq-plugin.mk

NO_AUTOPATCH += rabbitmq_aws

# FIXME: Use erlang.mk patched for RabbitMQ, while waiting for PRs to be
# reviewed and merged.

ERLANG_MK_REPO = https://github.com/rabbitmq/erlang.mk.git
ERLANG_MK_COMMIT = rabbitmq-tmp

include rabbitmq-components.mk
include erlang.mk

# --------------------------------------------------------------------
# Testing.
# --------------------------------------------------------------------

plt: PLT_APPS += rabbit rabbit_common ranch mnesia ssl compiler crypto common_test inets sasl ssh test_server snmp xmerl observer runtime_tools tools debugger edoc syntax_tools et os_mon hipe public_key webtool wx asn1 otp_mibs

TEST_CONFIG_FILE=$(CURDIR)/etc/rabbit-test

WITH_BROKER_TEST_COMMANDS := autocluster_all_tests:run()
