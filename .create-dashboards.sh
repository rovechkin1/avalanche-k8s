#!/bin/bash
set -e
if [ $# == 0 ]; then
        echo "Arguments: <dashboard-dir> <grafana-ip> <grafana-pwd>"
fi

set +e
which jq
if [ $? != 0 ]; then
        echo "install jq"
        apt update
        apt install jq
fi
set -e

# find notification channel
notif_chan=$(curl http://admin:$3@$2:80/api/alert-notifications | jq '.[0].uid')

# find avalanche folder
folder_id=$(curl -s admin:$3@$2:80/api/folders | \
        jq '.[] | select(.title=="avalanche")' | jq '.id')
if [ "$folder_id" == "" ]; then
        # create folder if not found
        out=$(curl -s -X POST  -H 'content-type:application/json;' \
                http://admin:$3@$2:80/api/folders \
                --data '{"title": "avalanche"}')
        folder_id=$(echo $out  | sed  -E 's/^.*"id":([^,]+),.*$/\1/g')
else
        echo "Folder avalanche exists, id:$folder_id"
fi

# add folder id
for i in $(ls "$1")
do
        echo -e "\nCreating $i dashboard"
        # set source type
        dashboard=$(sed -E 's/\$\{DS_PROMETHEUS\}/Prometheus/g' $1/$i)
        if [ "$notif_chan" != null ]; then
                cmd="echo \$dashboard | sed -E 's/\"notifications\": \[\]/\"notifications\": [{\"uid\":$notif_chan}]/g'"
        else
                cmd="echo \$dashboard"
        fi
        dashboard=$(eval $cmd)
        # create dashboard
        curl -s -X POST --data \
                "{\"dashboard\":$(echo $dashboard),
                \"overwrite\":true, \
                \"folderId\":$(echo $folder_id)}" \
                -H 'content-type:application/json;' \
                http://admin:$3@$2:80/api/dashboards/db 
done
