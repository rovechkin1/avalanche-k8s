## Running Avalanche Validator on Kubernetes

This project deploys Avalanche Validator into k8s cluster. It uses Prometheus operator for monitoring.
For details see this [Medium article](https://rovechkin-56984.medium.com/running-avalanche-validator-using-kubernetes-dd255461fc55)

## Prerequisites
```
# clone project with submodules
git clone --recursive https://github.com/rovechkin1/avalanche-k8s
```
### Clone submodules
```
# add submodules after regular clone
git submodule update --init --recursive
```

### Install helm
```
brew install helm
```

## Installing on GCP
### Create cluster using cli
```
./deploy-cli.sh create-cluster cluster-1
```
### Manually creating cluster
Use gcloud web console to create cluster
```
# Recommended k8s cluster:
# 1-2 Nodes
# Each node 1 CPU/4GB RAM
# Disk size 200GB
# approximate cost: $30/month for 1 node

# get k8s cluster credentials
gcloud container clusters get-credentials <cluster-name> --zone us-central1-c --project <project-name>
```

### Install prometheus and avalanche node with a new staking key
```
./deploy-cli.sh deploy all
```

### Obtain staking key from running node
```
./avax-cli.sh staking get ./staking.tgz
```
Keep it in a safe place in case node needs to be re-created.

### Install prometheus and avalanche node with existing staking key
```
tar xvf staking.tgz
./deploy-cli.sh -k staking deploy all
```

### Delete prometheus and avalanche
```
./deploy-cli.sh delete all
```

## Update

### Update avalanche
Update values in kube-avax/values.yaml
```
./deploy-cli.sh upgrade avalanche
```

### Update dashboards
This creates or overwrites existing dashboards
```
./deploy-cli.sh deploy dashboards "node-monitoring/dashboards" <grafana-password>
```

## Monitoring

### Grafana
```
./port-forward.sh grafana
```
Use browser on locahost:3000
user: admin
password: prom-operator

See 'Kubernetes / Compute Resources / Pod -> avalalanche'

### Grafana Alarms
Alarms can be be configured to post messages to telegram. To add this functionality after prometheus and grafana are deployed, follow these steps:
1. Create telegram chat and obtain chat id using telegram web interface. Go to your channel and observe its url: https://web.telegram.org/#/im?p=gXXXXXXXX
XXXXXXXX is the channel id
2. Create telegram bot and obtain its api key from botfather in the form XXXXX:YYYYYYYYYYYY
3. Configure telegram notification in grafana
```
./deploy-cli.sh create-alerts telegram <channel-id> <telegram-bot-api-key>
```
4. Redeploy dashboards
```
./deploy-cli.sh deploy dashboards node-monitoring/dashboards
```
5. Connect to grafana using port forward and test the alerts using
```
./port-forward.sh grafana
```

## Miscellaneous
### Connect to Avalanche Node Management Port
Via browser
```
./port-forward.sh avalanche
```

Via terminal
```
./avax-cli.sh exec
# 'exit' to exit
```


### Configure prometheus repo 
This step is optional unless installing
prometheus from repo. For that need to change deploi-cli.sh::deploy_prometheus()
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add stable https://charts.helm.sh/stable
helm repo update
```

### Get all peers
```
curl  -X POST --data '{
    "jsonrpc":"2.0",
    "id"     :1,
    "method" :"info.peers"
}' -H 'content-type:application/json;' 127.0.0.1:9650/ext/info
```


