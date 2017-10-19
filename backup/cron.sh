#!/bin/sh

function do_request(){
  KUBE_NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
  KUBE_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  SECRET_DATA=$(cat /backupdb/heketi.db.gz | base64)
  cat <<EOF > /tmp/data.json
{
  "kind": "Secret",
  "apiVersion": "v1",
  "metadata": {
    "name": "heketi-db-backup",
    "namespace": "$KUBE_NAMESPACE",
  },
  "data": {
    "heketi.db.gz": "$SECRET_DATA"
  },
  "type": "Opaque"
}
EOF
  curl -sSk -XPUT -d @/tmp/data.json -H "Content-Type: application/json" \
      -H "Authorization: Bearer $KUBE_TOKEN" \
      https://kubernetes.default:443/api/v1/namespaces/$KUBE_NAMESPACE/secrets/heketi-db-backup > /dev/null
}

while true
do
  test $(curl http://localhost:8080) || exit
  gzip -c $HEKETI_DB > /backupdb/heketi.db.gz
  do_request
  sleep 60
done
