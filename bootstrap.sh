#!/bin/bash

# Bootstrap cluster
multipass launch --name k3s-master --cpus 1 --mem 2048M --disk 10G
multipass launch --name k3s-node1 --cpus 1 --mem 2048M --disk 15G
multipass launch --name k3s-node2 --cpus 1 --mem 2048M --disk 15G
multipass exec k3s-master -- /bin/bash -c "curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE=644 sh -"
export K3S_TOKEN="$(multipass exec k3s-master -- /bin/bash -c "sudo cat /var/lib/rancher/k3s/server/node-token")"
export K3S_IP_SERVER="https://$(multipass info k3s-master | grep "IPv4" | awk -F' ' '{print $2}'):6443"
multipass exec k3s-node1 -- /bin/bash -c "curl -sfL https://get.k3s.io | K3S_TOKEN=${K3S_TOKEN} K3S_URL=${K3S_IP_SERVER} sh -"
multipass exec k3s-node2 -- /bin/bash -c "curl -sfL https://get.k3s.io | K3S_TOKEN=${K3S_TOKEN} K3S_URL=${K3S_IP_SERVER} sh -"
multipass exec k3s-master -- /bin/bash -c "cat /etc/rancher/k3s/k3s.yaml" | sed "s%https://127.0.0.1:6443%${K3S_IP_SERVER}%g" | sed "s/default/k3s/g" > ~/.kube/k3s.yaml
export KUBECONFIG=~/.kube/k3s.yaml
multipass exec k3s-master -- /bin/bash -c "sudo mkdir -p /var/lib/rancher/audit"
multipass exec k3s-master -- /bin/bash -c "wget https://raw.githubusercontent.com/falcosecurity/evolution/master/examples/k8s_audit_config/audit-policy.yaml"
multipass exec k3s-master -- /bin/bash -c "sudo cp audit-policy.yaml /var/lib/rancher/audit/"
sleep 2

# Install falco + falcosdekick + webui
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco -f custom-rules.yaml  --set falcosidekick.enabled=true --set falcosidekick.webui.enabled=true --set falcosidekick.image.tag=latest --set falcosidekick.webui.image.tag=v1-beta --set auditLog.enabled=true --set falcosidekick.config.kubeless.namespace=kubeless --set falcosidekick.config.kubeless.function=delete-pod -n falco --create-namespace

# Set up audit log endpoint (falco)
export FALCO_SVC_ENDPOINT=$(kubectl get svc -n falco --field-selector metadata.name=falco -o=json | jq -r ".items[] | .spec.clusterIP")
cat <<EOF > webhook-config.yaml
apiVersion: v1
kind: Config
clusters:
- name: falco
  cluster:
    server: http://${FALCO_SVC_ENDPOINT}:8765/k8s-audit
contexts:
- context:
    cluster: falco
    user: ""
  name: default-context
current-context: default-context
preferences: {}
users: []
EOF
multipass transfer webhook-config.yaml k3s-master:/tmp/
multipass exec k3s-master -- /bin/bash -c "sudo cp /tmp/webhook-config.yaml /var/lib/rancher/audit/"
multipass exec k3s-master -- /bin/bash -c "sudo sed -i '/^$/d' /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo chmod o+w /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo echo '    --kube-apiserver-arg=audit-log-path=/var/lib/rancher/audit/audit.log \' >> /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo echo '    --kube-apiserver-arg=audit-policy-file=/var/lib/rancher/audit/audit-policy.yaml \' >> /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo echo '    --kube-apiserver-arg=audit-webhook-config-file=/var/lib/rancher/audit/webhook-config.yaml \' >> /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo chmod o-w /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo systemctl daemon-reload"
multipass exec k3s-master -- /bin/bash -c "sudo systemctl restart k3s"

# Install kubeless
export RELEASE=$(curl -s https://api.github.com/repos/kubeless/kubeless/releases/latest | grep tag_name | cut -d '"' -f 4)
kubectl create ns kubeless
kubectl create -f https://github.com/kubeless/kubeless/releases/download/$RELEASE/kubeless-$RELEASE.yaml
cat <<EOF | kubectl apply -n kubeless -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: falco-pod-delete
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: falco-pod-delete-cluster-role
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "delete"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: falco-pod-delete-cluster-role-binding
roleRef:
  kind: ClusterRole
  name: falco-pod-delete-cluster-role
  apiGroup: rbac.authorization.k8s.io
subjects:
  - kind: ServiceAccount
    name: falco-pod-delete
    namespace: kubeless
EOF
cat <<EOF | kubectl apply -n kubeless -f -
apiVersion: kubeless.io/v1beta1
kind: Function
metadata:
  finalizers:
    - kubeless.io/function
  generation: 1
  labels:
    created-by: kubeless
    function: delete-pod
  name: delete-pod
spec:
  checksum: sha256:a68bf570ea30e578e392eab18ca70dbece27bce850a8dbef2586eff55c5c7aa0
  deps: |
    kubernetes>=12.0.1
  function-content-type: text
  function: |-
    from kubernetes import client,config

    config.load_incluster_config()

    def delete_pod(event, context):
        rule = event['data']['rule'] or None
        output_fields = event['data']['output_fields'] or None

        if rule and rule == "Terminal shell in container" and output_fields:
            if output_fields['k8s.ns.name'] and output_fields['k8s.pod.name']:
                pod = output_fields['k8s.pod.name']
                namespace = output_fields['k8s.ns.name']
                print (f"Deleting pod \"{pod}\" in namespace \"{namespace}\"")
                client.CoreV1Api().delete_namespaced_pod(name=pod, namespace=namespace, body=client.V1DeleteOptions())
  handler: delete-pod.delete_pod
  runtime: python3.7
  deployment:
    spec:
      template:
        spec:
          serviceAccountName: falco-pod-delete
EOF
