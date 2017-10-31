## Heketi in kubernetes

This README explain how to use this heketi image in Kubernetes to manage a GlusterFS cluster OUTSIDE of kurbernetes.

For other types of deployments, please see the official heketi wiki --> https://github.com/heketi/heketi/wiki/Kubernetes-Integration

### Requirements

* GlusterFS cluster
* Kubernetes cluster

### Setup heketi ssh keypair

* Create key

```shell
# On your local machine
$ ssh-keygen -t rsa -b 2048 -N '' -f ./id_rsa
# Push the public key on your gluster servers
```

* Create key secrets and configmap

```shell
kubectl create ns heketi
kubectl create secret -n heketi generic priv-key --from-file=./id_rsa
```

### Create temporary heketi deployment

```yaml
cat <<EOF > deployment-tmp.yaml
kind: Deployment
apiVersion: extensions/v1beta1
metadata:
  labels:
    app: heketi
  name: heketi
  namespace: heketi
spec:
  replicas: 1
  template:
    metadata:
      labels:
        app: heketi
    spec:
      containers:
      - name: heketi
        image: fhardy/heketi:latest
        imagePullPolicy: Always
        env:
        - name: HEKETI_FSTAB
          value: "/var/lib/heketi/fstab"
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: heketi-config
          mountPath: "/etc/heketi"
        - name: heketi-private-key
          mountPath: "/root/.ssh"
          readOnly: true
        - name: heketi-storage
          mountPath: "/var/lib/heketi"
        readinessProbe:
          timeoutSeconds: 3
          initialDelaySeconds: 3
          httpGet:
            path: "/hello"
            port: 8080
        livenessProbe:
          timeoutSeconds: 3
          initialDelaySeconds: 30
          httpGet:
            path: "/hello"
            port: 8080
      volumes:
      - name: heketi-private-key
        secret:
          secretName: priv-key
          defaultMode: 0600
      - name: heketi-config
        configMap:
          name: config
EOF
```

*heketi-config* volume is our configuration file *heketi.json*.

We just need to specify two things :

* ssh connection information. Ex :

  ```json
  [...]
  "glusterfs": {
    "executor": "ssh",
    "sshexec": {
      "port": "22",
      "keyfile": "/root/.ssh/id_rsa",
      "user": "myuser",
      "sudo": true
  },
  [...]
  ```

* db path :

  ```json
  [...]
  "db": "/var/lib/heketi/heketi.db"
  [...]
  ```

For more options, please see official wiki :)

```shell
# Create configmap with our configuration file
kubectl create cm -n heketi config --from-file=heketi.json
# Create temp deployment
kubectl create -f deployment-tmp.yaml
# Check if everything is okay
kubectl logs -n heketi heketi-79fb568798-pbgfm
```

### Setup persitent storage

* Create topology and storage

  ```shell
  # Port-forward heketi API
  kubectl port-forward heketi-79fb568798-pbgfm :8080
  # Load your topology from your local machine
  export HEKETI_CLI_SERVER=http://localhost:37471
  heketi-cli topology load --json=topology.json
  # Everything should be ok...
  heketi-cli cluster list
  # Is that ok ^ ? If it's not, you (or I..) probably missed something.
  heketi-cli volume create --size=2 --name=heketidbstorage
  # You should now have a gluster volume created
  ```

* Setup storage

  ```shell
  # Retrieve heketi database locally
  $ kubectl cp heketi-79fb568798-pbgfm:/var/lib/heketi/heketi.db /tmp/heketi.db
  # Now, mount the recently created glusterfs volume, and copy the db file into it.
  gluster volume list
  mount -t glusterfs 10.20.30.1:/heketidbstorage /mnt
  cp /tmp/heketi.db /mnt/
  umount /mnt
  ```

### Create heketi kubernetes service

We need 5 kubernetes objects :

* Endpoints for our glusterfs cluster. This will be used by the heketi API
  to mount our glusterfs volume which contains the database file:

  ```yaml
  cat <<EOF > endpoints.yaml
  kind: Endpoints
  apiVersion: v1
  metadata:
    name: "heketi-storage-endpoints"
    namespace: heketi
  subsets:
  - addresses:
    - ip: "10.20.30.1"
    ports:
    - port: 1
  - addresses:
    - ip: "10.20.30.2"
    ports:
    - port: 1
  - addresses:
    - ip: "10.20.30.3"
    ports:
    - port: 1
  EOF
  ```
* 2 services, 1 for glusterfs endpoints, the other for the heketi API:

  ```
  cat <<EOF > services.yaml
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: heketi
  spec:
    selector:
      app: heketi
    ports:
    - name: heketi
      port: 8080
      targetPort: 8080

  ---
  kind: Service
  apiVersion: v1
  metadata:-
    name: heketi-storage-endpoints
    namespace: heketi
  spec:
   ports:
   - port: 1
     targetPort: 0
  EOF
  ```

* Heketi API deployment:

  ```
  cat <<EOF > deployment.yaml
  kind: Deployment
  apiVersion: extensions/v1beta1
  metadata:
    labels:
      app: heketi
    name: heketi
    namespace: heketi
  spec:
    replicas: 1
    template:
      metadata:
        labels:
          app: heketi
      spec:
        serviceAccountName: heketi
        containers:
        - name: heketi
          image: fhardy/heketi:latest
          imagePullPolicy: Always
          env:
          - name: HEKETI_FSTAB
            value: "/var/lib/heketi/fstab"
          ports:
          - containerPort: 8080
          volumeMounts:
          - name: heketi-config
            mountPath: "/etc/heketi"
          - name: heketi-private-key
            mountPath: "/root/.ssh"
            readOnly: true
          - name: heketi-storage
            mountPath: "/var/lib/heketi"
          readinessProbe:
            timeoutSeconds: 3
            initialDelaySeconds: 3
            httpGet:
              path: "/hello"
              port: 8080
          livenessProbe:
            timeoutSeconds: 3
            initialDelaySeconds: 30
            httpGet:
              path: "/hello"
              port: 8080
        volumes:
        - name: heketi-private-key
          secret:
            secretName: priv-key
            defaultMode: 0600
        - name: heketi-config
          configMap:
            name: config
        - name: "heketi-storage"
          glusterfs:
            endpoints: "heketi-storage-endpoints"
            path: heketidbstorage
  EOF
  ```

* Finally, the storage class object:

  ```
  cat <<EOF > storageclass.yaml
  apiVersion: storage.k8s.io/v1beta1
  kind: StorageClass
  metadata:
    name: default
    annotations:
      storageclass.kubernetes.io/is-default-class: 'true'
  provisioner: kubernetes.io/glusterfs
  parameters:
  # heketi-cli cluster list
    clusterid: "be3dd04cbb6f5c6e1b3453ef05ed33bf"
  # kubectl get svc -n heketi # does not resolv internal dns...
    resturl: "http://10.233.42.13:8080"
    restuser: "CAN BE ANYTHING"
    restuserkey: "CAN BE ANYTHING"
    volumetype: "replicate:2"
  reclaimPolicy: Retain
  EOF
  ```

### Test

Create a persitent volume claim:

```yaml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: share
  namespace: share
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
```

This should work :)
