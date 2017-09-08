This example shows how to create a static RabbitMQ cluster using:

1. [Docker compose](https://docs.docker.com/compose/) 

2. [etcd2](https://github.com/coreos/etcd) as back-end

---

It creates a cluster with 2 nodes and the UI enabled. 

You can customize the `rabbitmq.config` inside `conf/rabbitmq.config`


How to run:
```
docker-compose up
```


---

Check running status:

- RabbitMQ Management: http://localhost:15672/#/


 