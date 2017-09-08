This example shows how to create a static RabbitMQ cluster using:
- [Docker compose](https://docs.docker.com/compose/) 
- [etcd2](https://github.com/coreos/etcd) as back-end

---

How to run:
```
docker-compose up
```

It creates a cluster with 2 nodes and the UI enabled. 

You can customize the `rabbitmq.config` inside `conf/rabbitmq.config`

 