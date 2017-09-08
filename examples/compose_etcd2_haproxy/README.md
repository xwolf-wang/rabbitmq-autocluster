This example shows how to create a dynamic RabbitMQ cluster using:


1. [Docker compose](https://docs.docker.com/compose/) 

2. [etcd2](https://github.com/coreos/etcd) as back-end  

3. [HA proxy](https://github.com/docker/dockercloud-haproxy)

---

You can customize the `rabbitmq.config` inside `conf/rabbitmq.config`


How to run:
```
docker-compose up
```

How to scale:

```
docker-compose scale rabbit=3
```

---

Check running status:

- RabbitMQ Management: http://localhost:15672/#/

