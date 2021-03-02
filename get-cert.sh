#!/bin/bash

set -euf -o pipefail

CLUSTER="development"
PROJECT=
NAMESPACE=
GLOBAL_OUTPUT_PATH="$(pwd)"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -c|--cluster) CLUSTER="$2"; shift ;;
    -n|--namespace) NAMESPACE="$2"; shift ;;
    -o|--outpath) GLOBAL_OUTPUT_PATH="$2"; shift ;;
    -p|--project) PROJECT="$2"; shift ;;
    -h|--help)
        echo -e "$0 [options]"
        echo ""
        echo "   -h, --help              show this command reference"
	echo "   -c, --cluster string    name of rancher cluster (default development)"
        echo "   -n, --namespace string  namespace for the spin2 deployment (required)"
	echo "   -o, --outputpath string directory to write output (default ${GLOBAL_OUTPUT_PATH})"
        echo "   -p, --project string    project name"
        exit 0
        ;;
    *)echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

function required_flag_or_error() {
  if [[ -z  "$1" ]]; then
    >&2 echo "ERROR: ${2}"
    exit 1
  fi
}

required_flag_or_error "$CLUSTER" "Cluster not set."
required_flag_or_error "$PROJECT" "You are required to supply a project name via -p or --project."
required_flag_or_error "$NAMESPACE" "You are required to supply a namespace via -n or --namespace."
required_flag_or_error "$GLOBAL_OUTPUT_PATH" "You are required to supply an output path via -o or --outputpath."

export NAMESPACE="$NAMESPACE"
export GLOBAL_OUTPUT_PATH="$GLOBAL_OUTPUT_PATH"
export EMAIL="$USER@lbl.gov"

mkdir -p $GLOBAL_OUTPUT_PATH

# default options to pass to kubectl
FLAGS="--namespace=${NAMESPACE}"

# directory containing this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"


export CERT_HOST_NAME="lb.${NAMESPACE}.${CLUSTER}.svc.spin.nersc.org"

SPIN_MODULE="spin/2.0"
RANCHER_MAJOR_VERSION_REQUIRED=2

if declare -F module; then
  module unload spin/1.0 || true
  module load "${SPIN_MODULE}"
fi

if declare -F module; then
  module load "${SPIN_MODULE}"
fi

if ! which rancher; then
  >&2 echo "ERROR: Required program 'rancher' not found."
  exit 6
fi

RANCHER_VERSION=$(rancher --version | sed -e 's/rancher version v\([0-9.]\+\)/\1/')
RANCHER_MAJOR_VERSION="${RANCHER_VERSION%%.*}"

if [[ "${RANCHER_MAJOR_VERSION}" -ne "${RANCHER_MAJOR_VERSION_REQUIRED}" ]]; then
  >&2 echo "ERROR: rancher v${RANCHER_MAJOR_VERSION_REQUIRED}.x required, version v${RANCHER_VERSION} found."
  exit 7
fi

if ! rancher project; then
  >&2 echo "ERROR: No rancher authentication token is present."
  exit 8 
fi

CONTEXT=$(rancher context switch < /dev/null | grep "${CLUSTER}.*${PROJECT}" | sed -E "s%.* ${CLUSTER} +([^ ]*) +${PROJECT}%\1%")
rancher context switch $CONTEXT

# Get dependency mo
MO_EXE="${SCRIPT_DIR}/lib/mo"
if [[ ! -x "${MO_EXE}" ]]; then
  mkdir -p "$(dirname "$MO_EXE")"
  curl -sSL https://git.io/get-mo -o "${MO_EXE}"
  chmod +x "${MO_EXE}"
fi

DEPLOY_TMP="${SCRIPT_DIR}/deploy_tmp"
mkdir -p "$DEPLOY_TMP"
rm -rf "$DEPLOY_TMP/*"

# does replacement of **exported** environment variables enclosed in double braces
# such as {{API_ROOT}}
for TEMPLATE in $(find "${SCRIPT_DIR}/" -name '*.yaml.template'); do
  "${MO_EXE}" -u "${TEMPLATE}" > "${DEPLOY_TMP}/$(basename ${TEMPLATE%.*})"
done

if ! rancher inspect --type namespace "${NAMESPACE}"; then
  rancher namespace create "${NAMESPACE}"
fi

## Create get-cert pod
rancher kubectl apply $FLAGS -f "${DEPLOY_TMP}/get-cert.yaml"
rancher kubectl apply $FLAGS -f "${DEPLOY_TMP}/lb.yaml"

# wait for ingress to be ready
# from https://stackoverflow.com/questions/35179410
external_ip=""
while [ -z $external_ip ]; do
  echo "Waiting for end point..."
  external_ip=$(rancher kubectl get $FLAGS ingress.extensions/lb --template="{{range .status.loadBalancer.ingress}}{{.ip}}{{end}}")
  [ -z "$external_ip" ] && sleep 5
done

# some times Let's Encrypt can not validate, so give a little more time for DNS to be ready
sleep 5
echo "load balancer ready"

KEY="${GLOBAL_OUTPUT_PATH}/${CERT_HOST_NAME}.key"
touch $KEY
chmod 600 $KEY
CERT="${GLOBAL_OUTPUT_PATH}/${CERT_HOST_NAME}.cert"

rancher kubectl exec deployment.apps/get-cert $FLAGS -i -t -- certbot certonly -n --standalone --agree-tos --email $EMAIL -d $CERT_HOST_NAME
rancher kubectl exec deployment.apps/get-cert $FLAGS -i -t -- cat "/etc/letsencrypt/live/$CERT_HOST_NAME/fullchain.pem" > "$CERT"
rancher kubectl exec deployment.apps/get-cert $FLAGS -i -t -- cat "/etc/letsencrypt/live/$CERT_HOST_NAME/privkey.pem" > "$KEY"

rancher kubectl delete $FLAGS deployment.apps/get-cert
rancher kubectl delete $FLAGS ingress.extensions/lb
