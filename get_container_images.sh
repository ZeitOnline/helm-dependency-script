#!/bin/bash

# This script lists all pods in a Kubernetes cluster that use a container image
# matching the specified search term. It outputs the namespace, pod name, and image name.
#
# Usage:
#   ./get_container_images.sh <search_term> [options]
#   Options:
#     -n, --namespace <namespace>    Restrict search to specified namespace
#
# Examples:
#   ./get_container_images.sh bitnami             # Search all namespaces
#   ./get_container_images.sh bitnami -n default  # Search only in default namespace

# Show usage if no search term provided
show_usage() {
  echo "Usage: $0 <search_term> [options]"
  echo ""
  echo "This script lists all pods that use container images matching the specified search term."
  echo ""
  echo "Options:"
  echo "  -n, --namespace <namespace>    Restrict search to specified namespace"
  echo ""
  echo "Examples:"
  echo "  $0 bitnami             # Search all namespaces for bitnami images"
  echo "  $0 redis -n default    # Search only default namespace for redis images"
  exit 1
}

# Initialize variables
NAMESPACE=""

# Parse arguments
if [ $# -eq 0 ]; then
  show_usage
fi

SEARCH_TERM="$1"
shift

# Process any additional options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      if [ -z "$2" ]; then
        echo "Error: Namespace argument missing"
        show_usage
      fi
      NAMESPACE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      show_usage
      ;;
  esac
done

# Set up namespace handling for kubectl commands
if [ -n "$NAMESPACE" ]; then
  echo "Fetching pods with '$SEARCH_TERM' images in namespace '$NAMESPACE'..."
  NAMESPACE_ARG="-n $NAMESPACE"
  # We'll only process the specified namespace
  namespaces=("$NAMESPACE")
else
  echo "Fetching pods with '$SEARCH_TERM' images across all namespaces..."
  NAMESPACE_ARG="--all-namespaces"
  # Get all namespaces with pods
  namespaces=($(kubectl get pods --all-namespaces -o custom-columns=NAMESPACE:.metadata.namespace --no-headers | sort -u))
fi

# Process each namespace
for ns in "${namespaces[@]}"; do
    # Check if namespace has any matching images before proceeding
    has_match=$(
      kubectl get pods -n "$ns" -o jsonpath='{.items[*].spec.containers[*].image}' | grep -c "$SEARCH_TERM" || true
    )
    if [ "$has_match" -eq "0" ]; then
      has_match=$(
        kubectl get pods -n "$ns" -o jsonpath='{.items[*].spec.initContainers[*].image}' | grep -c "$SEARCH_TERM" || true
      )
      if [ "$has_match" -eq "0" ]; then
        continue
      fi
    fi

    echo "Namespace: $ns"
    echo "-----------"
    printf "%-70s %s\n" "IMAGE" "PODS"
    printf "%-70s %s\n" "-----" "----"

    # Get all matching images in this namespace
    images=$(
      (
        kubectl get pods -n "$ns" -o jsonpath='{range .items[*].spec.containers[*]}{.image}{"\n"}{end}'
        kubectl get pods -n "$ns" -o jsonpath='{range .items[*].spec.initContainers[*]}{.image}{"\n"}{end}'
      ) | grep "$SEARCH_TERM" | sort -u
    )

    # For each image, find all pods using it
    for img in $images; do
        # Find pods with this image
        pods=$(
          (
            kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
            kubectl get pods -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}'
          ) | grep -F "$img" | cut -f1 | sort -u | paste -sd ", " -
        )
        printf "%-70s %s\n" "$img" "$pods"
    done
    echo ""
done
