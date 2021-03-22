#!/bin/bash

multipass launch --name k3s-master --cpus 1 --mem 2048M --disk 5G
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
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco --set falcosidekick.enabled=true --set falcosidekick.webui.enabled=true --set falcosidekick.image.tag=latest --set falcosidekick.webui.image.tag=v1-beta --set auditLog.enabled=true -n falco --create-namespace
sleep 2
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
multipass exec k3s-master -- /bin/bash -c "sudo chmod o+w /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo echo '    --kube-apiserver-arg=audit-log-path=/var/lib/rancher/audit/audit.log \' >> /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo echo '    --kube-apiserver-arg=audit-policy-file=/var/lib/rancher/audit/audit-policy.yaml \' >> /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo echo '    --kube-apiserver-arg=audit-webhook-config-file=/var/lib/rancher/audit/webhook-config.yaml \' >> /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo chmod o-w /etc/systemd/system/k3s.service"
multipass exec k3s-master -- /bin/bash -c "sudo systemctl daemon-reload"
multipass exec k3s-master -- /bin/bash -c "sudo systemctl restart k3s"
