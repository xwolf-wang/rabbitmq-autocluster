This example show how to create a static RabbitMQ cluster using [Docker compose](https://docs.docker.com/compose/) and [etcd2](https://github.com/coreos/etcd) as back-end
==

Run:
```
docker-compose up
```

It creates a cluster with 2 nodes and the UI enabled. 
You can customize the `rabbitmq.config` inside `conf/rabbitmq.config`