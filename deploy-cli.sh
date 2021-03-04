#!/bin/bash
# adopted from here:https://medium.com/@Drew_Stokes/bash-argument-parsing-54f3b81a6a8f
set -e
function usage() {
   echo -e 'Usage: deploy-cli.sh <cmd> <params>'
   echo -e '\tdeploy <app>\t- deploy app: prometheus, avalanche, staking'
   echo -e '\t[--staking-key|-k <key-dir>] deploy all\t- deploy prometheus, avalanche'
   echo -e '\tupgrade <app>\t- upgrade app: avalanche'
   echo -e '\tdeploy staking <staking-key-dir>\t- deploy staking key'
   echo -e '\tdeploy dashboards <dashboard-dir>\t- deploy or update dashboards'
   echo -e '\tcreate-alerts <kind> <channel-id> <bottoken>\t- create grafana alerts, kind: telegram'
   echo -e '\tdelete <app>\t- delete app: prometheus, avalanche, staking'
   echo -e '\treset-pwd <app> <pwd>\t- reset app pwd. app: grafana'
   echo -e '\tcreate-cluster <cluster-name> [<gcloud-project-name>] [<zone>]\t- create k8s cluster'
}

# install password for grafana. Will be changed at the first login
grafana_pwd=prom-operator
ava_staking_secret=ava-staking
ava_namespace=avalanche
prom_namespace=prometheus
staking_key=""

function check_namespace() {
   set +e
   kubectl get namespace "$1" >/dev/null
   local err=$?
   set -e
   echo $err
}

function deploy_prometheus() {
   echo 'Deploying prometheus stack'
   err=$(check_namespace "$prom_namespace")
   if [ $err != 0 ]; then
      echo "Create namespace $prom_namespace"
      kubectl create namespace "$prom_namespace"
   fi

   # install from helm repo
   # helm install -n "$prom_namespace" prometheus-stack  prometheus-community/kube-prometheus-stack

   # install from this repo
   helm install -n "$prom_namespace" prometheus-stack  kube-prometheus-stack-10.1.0 -f k8s-prom-values.yaml

   wait_for_pod grafana "$prom_namespace"

   pod=$(kubectl get pod -n "$prom_namespace" --selector="app.kubernetes.io/instance=prometheus-stack,app.kubernetes.io/name=grafana" --output jsonpath='{.items[0].metadata.name}')

   kubectl exec -n "$prom_namespace" -it "$pod" -c grafana -- grafana-cli admin reset-admin-password "$grafana_pwd"
   echo "Prometheus node deployed. cli_pod/password admin/$grafana_pwd to login"
}

function deploy_avalanche() {
   echo 'Deploying avalanche node'

   if [ "$staking_key" != "" ]; then
      echo "Use staking key from $staking_key"
      deploy_staking_key "$staking_key"
   fi

   err=$(check_namespace "$ava_namespace")
   if [ $err != 0 ]; then
      echo "Create namespace $ava_namespace"
      kubectl create namespace "$ava_namespace"
   fi

   # check staking key
   set +e
   kubectl get secret "$ava_staking_secret" -n "$ava_namespace" 1>/dev/null
   err=$?
   set -e
   if [ "$err" == 0 ]; then
      echo "Found staking key $ava_staking_secret. Will use it for the node"
      opts="--set-string stakingKey=$ava_staking_secret"
   else
      echo -e "Staking key $ava_staking_secret is not found. Will create a new key.\nto extract the key use 'avax-cli.sh staking get <dest-file.tgz>'"
   fi
   helm install  -n "$ava_namespace" $opts ava-node kube-avax -f kube-avax-values.yaml

   # install utilities into cli container
   wait_for_pod cli "$ava_namespace"
   cli_pod=$(kubectl get pods -n "$ava_namespace" | grep cli | awk '{print $1}')
   kubectl exec -it "$cli_pod" -n "$ava_namespace" -- apt-get update
   kubectl exec -it "$cli_pod" -n "$ava_namespace" -- apt-get install -y jq

   echo 'Avalanche node deployed'
}

function deploy_staking_key() {
   err=$(check_namespace "$ava_namespace")
   if [ $err != 0 ]; then
      kubectl create namespace "$ava_namespace"
   fi
   echo "Create $ava_staking_secret staking secret"
   kubectl create secret generic "$ava_staking_secret" --from-file="$1"/staker.key \
            --from-file="$1"/staker.crt -n "$ava_namespace"
}
function wait_for_pod() {
   svc=
   for i in {1..20}
   do
      n=$(kubectl get pod -n "$2" |grep "$1" | grep Running | awk '{print $1}')
      if [ "$n" == "" ]; then
         sleep 5
      else
         # wait untill pod starts
         sleep 30
         break
      fi
   done
   if [ "$n" == "" ]; then
      echo "Wait for $1 timeout"
      exit 1
   fi
}

function wait_for_svc() {
   svc=
   for i in {1..20}
   do
      n=$(kubectl get service -n "$2" |grep "$1" |  awk '{print $1}')
      if [ "$n" == "" ]; then
         sleep 5
      else
         break
      fi
   done
   if [ "$n" == "" ]; then
      echo "Wait for $1 timeout"
      exit 1
   fi
}

function deploy_avalanche_dashboards() {
   echo 'Deploying avalanche dashboards'
   wait_for_svc grafana "$prom_namespace"
   grafana_ip=$(kubectl get service -n "$prom_namespace" |grep grafana | awk '{print $3}')
   cli_pod=$(kubectl get pods -n "$ava_namespace" | grep cli | awk '{print $1}')
   tar cfz /tmp/dashboards.tgz -C $1 . 
   tmp_dir=$(kubectl exec "$cli_pod" -n "$ava_namespace" -- mktemp -d -t ci-XXXXXXXXXX)
   kubectl cp /tmp/dashboards.tgz "$cli_pod:$tmp_dir" -n "$ava_namespace"
   set +e
   kubectl exec -it "$cli_pod" -n "$ava_namespace" -- mkdir "$tmp_dir"/dashboards
   set -e
   kubectl exec -it "$cli_pod" -n "$ava_namespace" -- tar xvf "$tmp_dir"/dashboards.tgz -C "$tmp_dir"/dashboards
   kubectl cp .create-dashboards.sh "$cli_pod:$tmp_dir" -n "$ava_namespace"
   kubectl exec -it "$cli_pod" -n "$ava_namespace" -- "$tmp_dir"/.create-dashboards.sh "$tmp_dir/dashboards" "$grafana_ip" "$2"
}

function delete_app() {
   echo "Will delete $1"
   helm delete $1 -n "$2"
   echo "$1 is deleted"
}

function delete_staking_key() {
   echo "Will delete $ava_staking_secret"
   set +e
   kubectl get secret "$ava_staking_secret" -n "$ava_namespace" 2&>/dev/null
   err=$?
   set -e
   if [ "$err" == 0 ]; then
      kubectl delete secret "$ava_staking_secret" -n "$ava_namespace"
      echo "$ava_staking_secret is deleted"
   else
      echo  "Staking key $ava_staking_secret is not found"
   fi
}

function upgrade_avalanche() {
   echo 'Upgrading avalanche node'

   # check staking key
   set +e
   kubectl get secret "$ava_staking_secret" -n "$ava_namespace" 1>/dev/null
   err=$?
   set -e
   if [ "$err" == 0 ]; then
      echo "Found staking key $ava_staking_secret. Will use it for the node"
      opts="--set-string stakingKey=$ava_staking_secret"
    fi
   helm upgrade  -n "$ava_namespace" $opts ava-node kube-avax -f kube-avax-values.yaml

   echo 'Avalanche node is upgraded'
}

function create_alerts() {
   provider=$1
   if [ "$provider" != "telegram" ]; then
      echo "only telegram provider is supported"
      exit 1
   fi
   channel=$2
   if [ "$channel" == "" ]; then
      echo "missing channel id"
      exit 1
   fi
   bottoken=$3
   if [ "$bottoken" == "" ]; then
      echo "missing bot token"
      exit 1
   fi
   pod=$(kubectl get pods -n "$ava_namespace" | grep cli | awk '{print $1}')
   ip=$(kubectl get service -n "$prom_namespace" |grep prometheus-stack-grafana | awk '{print $3}')

   cmd="kubectl exec -it $pod -n $ava_namespace -- curl -X POST --data '{
         \"name\": \"telegram\",
         \"type\": \"telegram\",
         \"settings\": {
            \"chatid\": \"-$channel\",
            \"bottoken\": \"$bottoken\"
         }
         }' -H 'content-type:application/json;' http://admin:$grafana_pwd@$ip/api/alert-notifications"
   eval "$cmd"
}

function create_cluster() {
   cluster=$1
   project=$2
   if [ "$project" == "" ]; then
      project=$(gcloud config get-value project)
   fi 
   zone="$3"
   if [ "$zone" == "" ]; then
      zone="us-central1-c"
   fi
   gcloud beta container --project "$project" \
      clusters create "$cluster" --zone "$zone" \
      --no-enable-basic-auth --cluster-version "1.16.15-gke.4300" \
      --machine-type "e2-standard-2" --image-type "COS" --disk-type "pd-standard" \
      --disk-size "100" --metadata disable-legacy-endpoints=true \
      --scopes "https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" \
      --num-nodes "1" --enable-stackdriver-kubernetes \
      --enable-ip-alias \
      --network "projects/$project/global/networks/default" \
      --subnetwork "projects/$project/regions/us-central1/subnetworks/default" \
      --default-max-pods-per-node "110" --no-enable-master-authorized-networks \
      --addons HorizontalPodAutoscaling,HttpLoadBalancing --enable-autoupgrade \
      --enable-autorepair --max-surge-upgrade 1 --max-unavailable-upgrade 0

   gcloud container clusters \
      get-credentials "$cluster" --zone "$zone" --project "$project"
}


if  [ $# == 0 ]; then
    usage
    exit 1
fi

PARAMS=""
while (( "$#" )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
   -k|--staking-key)
      shift
      staking_key=$1
      if [ "$staking_key" == "" ];then
         echo "Error: Missing staking key" >&2
         exit 1
      fi
      shift
      ;;
    -*|--*=) # unsupported flags
      echo "Error: Unsupported flag $1" >&2
      exit 1
      ;;
    *) # preserve positional arguments
      PARAMS="$PARAMS $1"
      shift
      ;;
  esac
done
# set positional arguments in their proper place
eval set -- "$PARAMS"

case "$1" in
   deploy)
      if [ -n "$2" ]; then
         app=$2
         if [ "$app" == "prometheus" ]; then
            deploy_prometheus
         elif [ "$app" == "avalanche" ]; then
            deploy_avalanche
         elif [ "$app" == "staking" ]; then
            deploy_staking_key $3
         elif [ "$app" == "dashboards" ]; then
            deploy_avalanche_dashboards "$3" "$grafana_pwd"
         elif [ "$app" == "all" ]; then
            deploy_prometheus
            deploy_avalanche
            deploy_avalanche_dashboards "node-monitoring/dashboards" "$grafana_pwd"
         else
            echo "Error: Unsupported '$app'. Supported: 'prometheus', 'avalanche' or 'all'" >&2
            exit 1  
         fi
      else
         echo "Error: Argument for $1 is missing" >&2
         exit 1
      fi
   ;;
   delete)
      set +e # ignore failures
      if [ -n "$2" ]; then
         app=$2
         if [ "$app" == "prometheus" ]; then
            delete_app prometheus-stack "$prom_namespace"
            kubectl delete namespace "$prom_namespace"
         elif [ "$app" == "avalanche" ]; then
            delete_app ava-node "$ava_namespace"
            kubectl delete namespace "$ava_namespace"
         elif [ "$app" == "staking" ]; then
            delete_staking_key
         elif [ "$app" == "all" ]; then
            delete_app prometheus-stack "$prom_namespace"
            delete_app ava-node "$ava_namespace"
            delete_staking_key

            err=$(check_namespace "$prom_namespace")
            if [ $err == 0 ]; then
               echo "Delete namespace $prom_namespace"
               kubectl delete namespace "$prom_namespace"
            fi

            err=$(check_namespace "$ava_namespace")
            if [ $err == 0 ]; then
               echo "Delete namespace $ava_namespace"
               kubectl delete namespace "$ava_namespace"
            fi
         else
            echo "Error: Unsupported '$app'. Supported: 'prometheus' or 'avalanche'" >&2
            exit 1  
         fi
      else
         echo "Error: Argument for $1 is missing" >&2
         exit 1
      fi
   ;;
   upgrade)
      if [ -n "$2" ]; then
         app=$2
         if [ "$app" == "avalanche" ]; then
            upgrade_avalanche
         else
            echo "Error: Unsupported '$app'. Supported: 'avalanche'" >&2
            exit 1  
         fi
      else
         echo "Error: Argument for $1 is missing" >&2
         exit 1
      fi
   ;;
   reset-pwd)
      if [ -n "$2" ]; then
         app=$2
         if [ "$app" == "grafana" ]; then
            if [ "$3" == "" ]; then
               echo "Missing pwd"
               exit 1
            fi
            wait_for_pod grafana "$prom_namespace"
            pod=$(kubectl get pod -n "$prom_namespace" --selector="app.kubernetes.io/instance=prometheus-stack,app.kubernetes.io/name=grafana" --output jsonpath='{.items[0].metadata.name}')
            kubectl exec -n "$prom_namespace" -it "$pod" -c grafana -- grafana-cli admin reset-admin-password "$3"
         else
            echo "Error: Unsupported '$app'. Supported: 'grafana'" >&2
            exit 1  
         fi
      else
         echo "Error: Argument for $1 is missing" >&2
         exit 1
      fi
   ;;
   create-alerts)
      create_alerts "$2" "$3" "$4"
   ;;
   create-cluster)
      if [ -n "$2" ]; then
         create_cluster "$2" "$3" "$4"     
      else
         echo "Error: Cluster name is missing" >&2
         exit 1
      fi
   ;;
   *)
      echo "Error: Unsupported command $1" >&2
      exit 1
   ;;
esac

