
Test RabbitMQ-Autoclsuter on K8s

 1. Install [`kubectl`](https://kubernetes.io/docs/tasks/kubectl/install/): 
```
# OS X
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/darwin/amd64/kubectl

# Linux
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl

chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
```
2.Install [`Minikube`](https://github.com/kubernetes/minikube/releases):

```
OSX

curl -Lo minikube https://storage.googleapis.com/minikube/releases/v0.17.1/minikube-darwin-amd64 && chmod +x minikube && sudo mv minikube /usr/local/bin/

Linux

curl -Lo minikube https://storage.googleapis.com/minikube/releases/v0.17.1/minikube-linux-amd64 && chmod +x minikube && sudo mv minikube /usr/local/bin/
```

3. Start `minikube` virtual machine:
`minikube start --cpus=2 --memory=2040 --vm-driver=virtualbox` 

4. Create a namespace only for RabbitMQ test:
`kubectl create namespace test-rabbitmq`

5. Run the `etcd` image and expose it:
```
kubectl run etcd --image=microbox/etcd --port=4001 --namespace=test-rabbitmq -- --name etcd
kubectl --namespace=test-rabbitmq expose deployment etcd
```
6. Build a [Docker image](https://github.com/rabbitmq/rabbitmq-autocluster/blob/master/Dockerfile)
```
git clone https://github.com/rabbitmq/rabbitmq-autocluster.git rabbitmq-autocluster
make dist
eval $(minikube docker-env)
docker build  . -t rabbitmq-autocluster
```
Wait until the image is created..

7.  Deploy the `YAML` (see above the definition) file:
`kubectl create -f examples/k8s_minikube/rabbitmq.yaml`

8. Check the cluster status:
 Wait a few seconds....then 
```
FIRST_POD=$(kubectl get pods --namespace test-rabbitmq -l 'app=rabbitmq' -o jsonpath='{.items[0].metadata.name }')
kubectl exec --namespace=test-rabbitmq $FIRST_POD rabbitmqctl cluster_status
```
as result:
```
Cluster status of node 'rabbit@172.17.0.9' ...
[{nodes,[{disc,['rabbit@172.17.0.7','rabbit@172.17.0.8',
                'rabbit@172.17.0.9']}]},
 {running_nodes,['rabbit@172.17.0.7','rabbit@172.17.0.8','rabbit@172.17.0.9']},
 {cluster_name,<<"rabbit@rabbitmq-deployment-3409700153-b1bv7">>},
 {partitions,[]},
 {alarms,[{'rabbit@172.17.0.7',[]},
          {'rabbit@172.17.0.8',[]},
          {'rabbit@172.17.0.9',[]}]}]
```


9. Expose the cluster using a load-balancer:

```
kubectl expose deployment rabbitmq-deployment --port 15672  --type=LoadBalancer  --namespace=test-rabbitmq

minikube service rabbitmq-deployment --namespace=test-rabbitmq 

kubectl scale rabbitmq-deployment --replicas=4
```

10. Optional enable the K8s dashboard:
```
minikube dashboard 
```
