#!/bin/bash
set -e
function usage() {
    echo -e 'Usage:'
    echo -e '\tinfo node\t- get node id'
    echo -e '\tinfo peers\t- get peer info'
    echo -e '\tinfo boot\t- check if bootstrapped'
    echo -e '\tinfo live\t- check if alive'
    echo -e '\tstaking get <dest-file.tgz>\t- get stacking key'
    echo -e '\tstaking view\t- view stacking secret'
    echo -e '\texec\t- connect to cli pod'
}

if  [ $# == 0 ]; then
    usage
    exit 1
fi

port=9650
ava_namespace=avalanche
PARAMS=""
while (( "$#" )); do
  case "$1" in
    -h|--help)
        usage
        exit 0
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

pod=$(kubectl get pods -n "$ava_namespace" | grep cli | awk '{print $1}')
ip=$(kubectl get service -n "$ava_namespace" |grep avalanchego | awk '{print $3}')
ava_staking_secret=ava-staking
case "$1" in
    info)
        case "$2" in
            node)
                kubectl exec -it "$pod" -n "$ava_namespace" -- curl -X POST --data '{
                "jsonrpc":"2.0",
                    "id"     :1,
                    "method" :"info.getNodeID"
                }' -H 'content-type:application/json;' "$ip":"$port"/ext/info
            ;;
            peers)
                kubectl exec -it "$pod" -n "$ava_namespace" --  curl -X POST --data '{
                    "jsonrpc":"2.0",
                        "id"     :1,
                        "method" :"info.peers"
                    }' -H 'content-type:application/json;' "$ip":"$port"/ext/info | jq
                ;;
            boot)
                kubectl exec -it "$pod" -n "$ava_namespace" --  curl -X POST --data '{
                    "jsonrpc":"2.0",
                    "id"     :1,
                    "method" :"info.isBootstrapped",
                    "params": {
                        "chain":"X"
                    }}' -H 'content-type:application/json;' "$ip":"$port"/ext/info
                ;;
            live)
                kubectl exec -it "$pod" -n "$ava_namespace" -- curl -s -f -I -X GET "$ip":"$port"/ext/health &>/dev/null && echo OK || echo FAIL
                ;;
            *)
                echo "Error: Unsupported command $1" >&2
                usage
                exit 1
                ;;
        esac
    ;;
    staking)
        case $2 in 
        get)
            ava_pod=$(kubectl get pods -n "$ava_namespace" | grep ava-node | awk '{print $1}')
            kubectl exec -it "$ava_pod" -n "$ava_namespace" -- tar cfz /tmp/staking.tgz -C /root/staking-keys staking
            kubectl cp "$ava_pod":/tmp/staking.tgz $3 -n "$ava_namespace"
            kubectl exec -it "$ava_pod" -n "$ava_namespace" -- rm /tmp/staking.tgz
        ;;
        view)
            ava_staking_secret=ava-staking
            set +e
            kubectl get secret "$ava_staking_secret" -n "$ava_namespace" 1>/dev/null
            err=$?
            set -e
            if [ "$err" == 0 ]; then
                kubectl describe secret "$ava_staking_secret" -n "$ava_namespace"
            else
                echo  "Staking key $ava_staking_secret is not found"
            fi
        ;;
        *)
            echo -e "Unsupported command. Supported: get"
            exit 1
        ;;
        esac
    ;;
    exec)
        echo "Use $ip:$port to connect to avalanche node"
        echo "Example: curl -I -X GET $ip:$port/ext/health"
        kubectl exec -it "$pod" -n "$ava_namespace" -- bash
        ;;
    *)
        echo -e "Unsupported command. Supported: info"
        exit 1
    ;;
esac


