#!/bin/bash

# Set working dir
wd="$(dirname "$(realpath -s $0)")"

source ${wd:?}/debug.sh

trap_to_debug_commands; # Trap commands (should be called only after sourcing debug.sh)

export VERSION="${ACM_VERSION}"
export OPERATOR_NAME="${ACM_OPERATOR_NAME}"
export BUNDLE_NAME="${ACM_BUNDLE_NAME}"
export NAMESPACE="${ACM_NAMESPACE}"
export CHANNEL="${ACM_CHANNEL}"
# export SUBSCRIBE=false

# Run on the Hub

export LOG_TITLE="cluster1"
# export KUBECONFIG=/opt/openshift-aws/smattar-cluster1/auth/kubeconfig
export KUBECONFIG="${KUBECONF_CLUSTER_A}"

# Deploy the operator
${wd:?}/downstream_push_bundle_to_olm_catalog.sh

# # Wait
# if ! (timeout 5m bash -c "until ${OC} get crds multiclusterhubs.operator.open-cluster-management.io > /dev/null 2>&1; do sleep 10; done"); then
#   error "MultiClusterHub CRD was not found."
#   exit 1
# fi

echo "# Wait for MultiClusterHub CRD to be ready"
cmd="${OC} get crds multiclusterhubs.operator.open-cluster-management.io"
watch_and_retry "$cmd" 10m || FATAL "MultiClusterHub CRD was not created"

# Create the MultiClusterHub instance
cat <<EOF | ${OC} apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: ${NAMESPACE}
spec:
  disableHubSelfManagement: true
EOF

# # Wait for the console url
# if ! (timeout 15m bash -c "until ${OC} get routes -n ${NAMESPACE} multicloud-console > /dev/null 2>&1; do sleep 10; done"); then
#   error "ACM Console url was not found."
#   exit 1
# fi
#
# # Print ACM console url
# echo ""
# info "ACM Console URL: $(${OC} get routes -n ${NAMESPACE} multicloud-console --no-headers -o custom-columns='URL:spec.host')"
# echo ""

echo "# Wait for ACM console url to be available"
cmd="${OC} get routes -n ${NAMESPACE} multicloud-console --no-headers -o custom-columns='URL:spec.host'"
watch_and_retry "$cmd" 10m || FATAL "ACM Console url is not ready"

# # Wait for multiclusterhub to be ready
# ${OC} get mch -o=jsonpath='{.items[0].status.phase}' # should be running
# if ! (timeout 5m bash -c "until [[ $(${OC} get MultiClusterHub multiclusterhub -o=jsonpath='{.items[0].status.phase}') -eq 'RUNNING' ]]; do sleep 10; done"); then
#   error "ACM Hub is not ready."
#   exit 1
# fi

echo "# Wait for multiclusterhub to be ready"
cmd="${OC} get MultiClusterHub multiclusterhub -o=jsonpath='{.items[0].status.phase}') -eq 'RUNNING'"
watch_and_retry "$cmd" 10m || FATAL "ACM Hub is not ready"

# Create the cluster-set
cat <<EOF | ${OC} apply -f -
apiVersion: cluster.open-cluster-management.io/v1alpha1
kind: ManagedClusterSet
metadata:
  name: submariner
EOF

# TODO: wait for managedclusterset to be ready
sleep 2m

# Bind the namespace
cat <<EOF | ${OC} apply -f -
apiVersion: cluster.open-cluster-management.io/v1alpha1
kind: ManagedClusterSetBinding
metadata:
  name: submariner
  namespace: ${SUBMARINER_NAMESPACE}
spec:
  clusterSet: submariner
EOF

# Define the managed Clusters
for i in {1..3}; do

  ### Create the namespace for the managed cluster
  ${OC} new-project cluster${i} || :
  ${OC} label namespace cluster${i} cluster.open-cluster-management.io/managedCluster=cluster${i} --overwrite

  # TODO: wait for namespace
  sleep 2m

  ### Create the managed cluster
cat <<EOF | ${OC} apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: cluster${i}
  labels:
    cloud: Amazon
    name: cluster${i}
    vendor: OpenShift
    cluster.open-cluster-management.io/clusterset: submariner
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF

  ### TODO: Wait for managedcluster
  sleep 1m

  ### Create the klusterlet addon config
cat <<EOF | ${OC} apply -f -
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: cluster${i}
  namespace: cluster${i}
  labels:
    cluster.open-cluster-management.io/submariner-agent: "true"
spec:
  applicationManager:
    argocdCluster: false
    enabled: true
  certPolicyController:
    enabled: true
  clusterLabels:
    cloud: auto-detect
    cluster.open-cluster-management.io/clusterset: submariner
    name: cluster${i}
    vendor: auto-detect
  clusterName: cluster${i}
  clusterNamespace: cluster${i}
  iamPolicyController:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
  version: 2.2.0
EOF

  ### Save the yamls to be applied on the managed clusters
  ${OC} get secret cluster${i}-import -n cluster${i} -o jsonpath={.data.crds\\.yaml} | base64 --decode > /tmp/cluster${i}-klusterlet-crd.yaml
  ${OC} get secret cluster${i}-import -n cluster${i} -o jsonpath={.data.import\\.yaml} | base64 --decode > /tmp/cluster${i}-import.yaml
done

# TODO: wait for kluserlet addon
sleep 1m

# Run on the managed clusters

# -### Import the clusters to the clusterSet
# for i in {1..3}; do
#   export LOG_TITLE="cluster${i}"
#   export KUBECONFIG=/opt/openshift-aws/smattar-cluster${i}/auth/kubeconfig
#   ${OC} login -u ${OCP_USR} -p ${OCP_PWD}
#
#   # Install klusterlet (addon) on the managed clusters
#   # Import the managed clusters
#   info "install the agent"
#   ${OC} apply -f /tmp/cluster${i}-klusterlet-crd.yaml
#
#   # TODO: Wait for klusterlet crds installation
#   sleep 2m
#
#   ${OC} apply -f /tmp/cluster${i}-import.yaml
#   info "$(${OC} get pod -n open-cluster-management-agent)"
#
# done

### Function to import the clusters to the clusterSet
function import_managed_cluster() {
  trap_to_debug_commands;

  local cluster_name="$(print_current_cluster_name)"
  # TODO: cluster counter should rather not be used. Need to create crd with function
  local cluster_counter="$1"

  ( # subshell to hide commands
    local cmd="${OC} login -u ${OCP_USR} -p ${OCP_PWD}"
    # Attempt to login up to 3 minutes
    watch_and_retry "$cmd" 3m
  )

  # Install klusterlet (addon) on the managed clusters
  # Import the managed clusters
  info "install the agent"
  ${OC} apply -f /tmp/cluster${cluster_counter}-klusterlet-crd.yaml

  # TODO: Wait for klusterlet crds installation
  sleep 2m

  ${OC} apply -f /tmp/cluster${cluster_counter}-import.yaml
  info "$(${OC} get pod -n open-cluster-management-agent)"

}

# ------------------------------------------

function import_managed_cluster_a() {
  PROMPT "Import ACM CRDs for managed cluster A"
  trap_to_debug_commands;

  export KUBECONFIG="${KUBECONF_CLUSTER_A}"
  import_managed_cluster "1"
}

# ------------------------------------------

function import_managed_cluster_c() {
  PROMPT "Import ACM CRDs for managed cluster C"
  trap_to_debug_commands;

  export KUBECONFIG="${KUBECONF_CLUSTER_C}"
  import_managed_cluster "1"
}

# ------------------------------------------

### Prepare Submariner
for i in {1..3}; do
  export LOG_TITLE="cluster${i}"
  export KUBECONFIG=/opt/openshift-aws/smattar-cluster${i}/auth/kubeconfig
  ${OC} login -u ${OCP_USR} -p ${OCP_PWD}

  # Install the submariner custom catalog source
  export VERSION="${SUBMARINER_VERSION}"
  export OPERATOR_NAME="submariner"
  export BUNDLE_NAME="submariner-operator-bundle"
  export NAMESPACE="${SUBMARINER_NAMESPACE}"
  export CHANNEL="${SUBMARINER_CHANNEL}"
  export SUBSCRIBE=false
  ${wd:?}/downstream_push_bundle_to_olm_catalog.sh

  ### Apply the Submariner scc
  ${OC} adm policy add-scc-to-user privileged system:serviceaccount:${SUBMARINER_NAMESPACE}:submariner-gateway
  ${OC} adm policy add-scc-to-user privileged system:serviceaccount:${SUBMARINER_NAMESPACE}:submariner-routeagent
  ${OC} adm policy add-scc-to-user privileged system:serviceaccount:${SUBMARINER_NAMESPACE}:submariner-globalnet
  ${OC} adm policy add-scc-to-user privileged system:serviceaccount:${SUBMARINER_NAMESPACE}:submariner-lighthouse-coredns
done

# TODO: Wait for acm agent installation on the managed clusters
sleep 3m

# Run on the hub
export LOG_TITLE="cluster1"
export KUBECONFIG=/opt/openshift-aws/smattar-cluster1/auth/kubeconfig
${OC} login -u ${OCP_USR} -p ${OCP_PWD}

### Install Submariner
for i in {1..3}; do
  ### Create the aws creds secret
cat <<EOF | ${OC} apply -f -
apiVersion: v1
kind: Secret
metadata:
    name: cluster${i}-aws-creds
    namespace: cluster${i}
type: Opaque
data:
    aws_access_key_id: $(echo ${AWS_KEY} | base64 -w0)
    aws_secret_access_key: $(echo ${AWS_SECRET} | base64 -w0)
EOF
  ### Create the Submariner Subscription config
cat <<EOF | ${OC} apply -f -
apiVersion: submarineraddon.open-cluster-management.io/v1alpha1
kind: SubmarinerConfig
metadata:
  name: submariner
  namespace: cluster${i}
spec:
  IPSecIKEPort: 501
  IPSecNATTPort: 4501
  cableDriver: libreswan
  credentialsSecret:
    name: cluster${i}-aws-creds
  gatewayConfig:
    aws:
      instanceType: m5.xlarge
    gateways: 1
  imagePullSpecs:
    lighthouseAgentImagePullSpec: ''
    lighthouseCoreDNSImagePullSpec: ''
    submarinerImagePullSpec: ''
    submarinerRouteAgentImagePullSpec: ''
  subscriptionConfig:
    channel: ${SUBMARINER_CHANNEL}
    source: my-catalog-source
    sourceNamespace: ${SUBMARINER_NAMESPACE}
    startingCSV: submariner.${SUBMARINER_VERSION}
EOF

  ### Create the Submariner addon to start the deployment
cat <<EOF | ${OC} apply -f -
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: submariner
  namespace: cluster${i}
spec:
  installNamespace: ${SUBMARINER_NAMESPACE}
EOF

  ### Label the managed clusters and klusterletaddonconfigs to deploy submariner
  ${OC} label managedclusters.cluster.open-cluster-management.io cluster${i} "cluster.open-cluster-management.io/submariner-agent=true" --overwrite
done

for i in {1..3}; do
  debug "$(${OC} get submarinerconfig submariner -n cluster${i} >/dev/null 2>&1 && ${OC} describe submarinerconfig submariner -n cluster${i})"
  debug "$(${OC} get managedclusteraddons submariner -n cluster${i} >/dev/null 2>&1 && ${OC} describe managedclusteraddons submariner -n cluster${i})"
  debug "$(${OC} get manifestwork -n cluster${i} --ignore-not-found)"
done

export LOG_TITLE=""
info "All done"
exit 0
