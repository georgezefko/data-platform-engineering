## install kind
brew install kind 

## install helm

brew install helm

## get contexts
Kubectl config get-contexts

## switch clusters

kubectl config use-context kind-development

##create cluster
kind create cluster --name development

 helm create kafka

##install kafka with helm
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install kafka bitnami/kafka --set replicaCount=1 --set controller.replicaCount=1 --set auth.enabled=false
# NAME: kafka
# LAST DEPLOYED: Sun Oct 20 13:57:53 2024
# NAMESPACE: default
# STATUS: deployed
# REVISION: 1
# TEST SUITE: None
# NOTES:
# CHART NAME: kafka
# CHART VERSION: 30.1.6
# APP VERSION: 3.8.0

# ** Please be patient while the chart is being deployed **

# Kafka can be accessed by consumers via port 9092 on the following DNS name from within your cluster:

#     kafka.default.svc.cluster.local

# Each Kafka broker can be accessed by producers via port 9092 on the following DNS name(s) from within your cluster:

#     kafka-controller-0.kafka-controller-headless.default.svc.cluster.local:9092

# The CLIENT listener for Kafka client connections from within your cluster have been configured with the following security settings:
#     - SASL authentication

# To connect a client to your Kafka, you need to create the 'client.properties' configuration files with the content below:

# security.protocol=SASL_PLAINTEXT
# sasl.mechanism=SCRAM-SHA-256
# sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required \
#     username="user1" \
#     password="$(kubectl get secret kafka-user-passwords --namespace default -o jsonpath='{.data.client-passwords}' | base64 -d | cut -d , -f 1)";

# To create a pod that you can use as a Kafka client run the following commands:

#     kubectl run kafka-client --restart='Never' --image docker.io/bitnami/kafka:3.8.0-debian-12-r5 --namespace default --command -- sleep infinity
#     kubectl cp --namespace default /path/to/client.properties kafka-client:/tmp/client.properties
#     kubectl exec --tty -i kafka-client --namespace default -- bash

#     PRODUCER:
#         kafka-console-producer.sh \
#             --producer.config /tmp/client.properties \
#             --bootstrap-server kafka.default.svc.cluster.local:9092 \
#             --topic test

#     CONSUMER:
#         kafka-console-consumer.sh \
#             --consumer.config /tmp/client.properties \
#             --bootstrap-server kafka.default.svc.cluster.local:9092 \
#             --topic test \
#             --from-beginning

# WARNING: There are "resources" sections in the chart not set. Using "resourcesPreset" is not recommended for production. For production installations, please set the following values according to your workload needs:
#   - controller.resources
# +info https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/

###
kubectl cp client.properties kafka-client:/tmp/client.properties --namespace default


##get kafka values
helm show values bitnami/kafka > values.yaml


###argo port forward
kubectl port-forward svc/argocd-server -n argocd-dev 8080:80
kubectl port-forward svc/argocd-server -n argocd 8080:443
kubectl port-forward svc/mageai -n develop 6789:6789
###install ingress
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

kubectl create secret docker-registry regcred \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=your-dockerhub-username \
  --docker-password=your-dockerhub-password \
  --docker-email=your-email@example.com \
  --namespace=develop

  kubectl create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=your-github-username \
  --docker-password=your-personal-access-token \
  --docker-email=your-email@example.com \
   --namespace=develop

imagePullSecrets:
  - name: regcred  # or ghcr-secret for GitHub

image:
  repository: your-dockerhub-username/your-image-name  # For Docker Hub
  # repository: ghcr.io/your-github-username/your-image-name  # For GitHub Container Registry
  pullPolicy: IfNotPresent
  tag: your-image-tag