#!/bin/bash

#
# Lists Helm releases and displays their dependency tree.
#
# Usage:
#   ./get_helm_deps.sh
#   ./get_helm_deps.sh -n <namespace>
#   ./get_helm_deps.sh -r, --recursive     Enable recursive dependency lookup
#
# Note: For GitHub Container Registry (ghcr.io) authentication, run this command before using the script:
#   gh auth token | helm registry login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
# 
# Requires: helm, jq, kubectl
#

# --- Parameters ---
NAMESPACE_ARG=""
RECURSIVE_LOOKUP="false"

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -n|--namespace)
      NAMESPACE_ARG="$2"
      shift 2
      ;;
    -r|--recursive)
      RECURSIVE_LOOKUP="true"
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--namespace <namespace>] [--recursive]"
      exit 1
      ;;
  esac
done

# --- Helper Functions ---

# Format and display error messages
print_error() {
    local error_message="$1"
    local error_details="$2"
    echo "  Error: $error_message"
    [[ -n "$error_details" ]] && echo "$error_details" | sed 's/^/    /'
}

# Extract dependencies from Chart.lock or Chart.yaml
extract_dependencies() {
    local file_path="$1"
    
    # Use jq to extract dependencies
    if [[ -f "$file_path" ]]; then
        jq '.dependencies' < "$file_path" 2>/dev/null
    fi
}

# Recursively resolve chart dependencies
resolve_dependencies() {
    local chart_name="$1"
    local chart_version="$2"
    local chart_repo="$3"
    local indent_level="$4"
    local skip_header="${5:-false}"
    local indent_str=$(printf "%*s" $((indent_level * 4)) "")
    local temp_dir

    # Skip local charts as they can't be downloaded
    if [[ "$chart_repo" == "file://"* || "$chart_repo" == "/" || "$chart_repo" == "./"* ]]; then
        [[ "$skip_header" != "false" ]] && echo "${indent_str}├── $chart_name:$chart_version [Local chart - skipped]"
        return 0
    fi

    # Create temp directory for chart download
    temp_dir=$(mktemp -d) || {
        [[ "$skip_header" != "false" ]] && echo "${indent_str}├── [Failed: temp directory creation error]"
        return 1
    }
    trap "rm -rf $temp_dir" EXIT

    # Download chart based on repository type (OCI vs HTTP)
    local success=false
    if [[ "$chart_repo" == "oci://"* ]]; then
        # OCI registry - try with version then without
        if helm pull "$chart_repo/$chart_name" --version "$chart_version" --untar -d "$temp_dir" &>/dev/null ||
           helm pull "$chart_repo/$chart_name" --untar -d "$temp_dir" &>/dev/null; then
            success=true
        fi
    else
        # HTTP repository - add repo if needed then pull
        local repo_name=$(echo "$chart_repo" | sed -E 's#^https?://##' | sed -E 's#[./]+#-#g')
        helm repo list | grep -q "$repo_name" || helm repo add "$repo_name" "$chart_repo" &>/dev/null
        if helm pull "$chart_name" --version "$chart_version" --repo "$chart_repo" --untar -d "$temp_dir" &>/dev/null; then
            success=true
        fi
    fi

    if [[ "$success" != "true" ]]; then
        [[ "$skip_header" != "false" ]] && echo "${indent_str}├── [Failed: download error]"
        return 1
    fi

    # Check for dependencies in Chart.lock (preferred) or Chart.yaml
    local chart_dir="$temp_dir/$chart_name"
    local nested_deps=""

    [[ -f "$chart_dir/Chart.lock" ]] && nested_deps=$(extract_dependencies "$chart_dir/Chart.lock")
    [[ -z "$nested_deps" || "$nested_deps" == "null" ]] && [[ -f "$chart_dir/Chart.yaml" ]] && nested_deps=$(extract_dependencies "$chart_dir/Chart.yaml")

    # Process dependencies if found
    if [[ "$nested_deps" != "null" && -n "$nested_deps" && "$nested_deps" != "[]" ]] && echo "$nested_deps" | jq '.' &>/dev/null; then
        # Print chart name if not already printed by parent
        [[ "$skip_header" == "false" ]] && echo "${indent_str}├── $chart_name:$chart_version"

        # Process each dependency and build the tree
        local dep_count=$(echo "$nested_deps" | jq 'length')
        local current=0

        echo "$nested_deps" | jq -r '.[] | "\(.name)\t\(.version)\t\(.repository)"' 2>/dev/null | \
        while IFS=$'\t' read -r dep_name dep_version dep_repo; do
            current=$((current+1))
            local tree_char="├──"
            [[ "$current" -eq "$dep_count" ]] && tree_char="└──"
            
            echo "${indent_str}${tree_char} $dep_name:$dep_version ($dep_repo)"
            
            # Recurse if recursive lookup is enabled
            [[ "$RECURSIVE_LOOKUP" == "true" ]] && resolve_dependencies "$dep_name" "$dep_version" "$dep_repo" $((indent_level + 1)) "true"
        done
    else
        [[ "$skip_header" == "false" ]] && echo "${indent_str}├── $chart_name:$chart_version [No dependencies]"
    fi
}

# --- Main Script ---

# Check for required tools
for cmd in helm jq kubectl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: required command '$cmd' not found. Please install it to continue."
        exit 1
    fi
done

# Set up helm command with namespace if specified
helm_list_cmd="helm list -o json"
if [[ -n "$NAMESPACE_ARG" ]]; then
    echo "Fetching Helm releases from namespace '$NAMESPACE_ARG'..."
    helm_list_cmd="$helm_list_cmd --namespace $NAMESPACE_ARG"
else
    echo "Fetching Helm releases from all namespaces..."
    helm_list_cmd="$helm_list_cmd --all-namespaces"
fi

echo "Recursive dependency lookup: $([[ "$RECURSIVE_LOOKUP" == "true" ]] && echo "enabled" || echo "disabled (use -r to enable)")"
echo

# Get all releases
releases_json=$($helm_list_cmd)
if [[ $? -ne 0 ]]; then
    print_error "Failed to list Helm releases."
    exit 1
fi

if [[ -z "$releases_json" || "$(echo "$releases_json" | jq 'length')" -eq 0 ]]; then
    echo "No Helm releases found."
    exit 0
fi

# Process each release
echo "$releases_json" | jq -c '.[]' | while IFS= read -r release_info; do
    # Extract release metadata
    name=$(echo "$release_info" | jq -r '.name')
    namespace=$(echo "$release_info" | jq -r '.namespace')
    chart_name_version=$(echo "$release_info" | jq -r '.chart')
    app_version=$(echo "$release_info" | jq -r '.app_version')
    status=$(echo "$release_info" | jq -r '.status')

    # Print release header
    echo "================================================================================"
    printf "%-14s %s\n" "Release:" "$name"
    printf "%-14s %s\n" "Namespace:" "$namespace"
    printf "%-14s %s\n" "Status:" "$status"
    printf "%-14s %s\n" "Chart:" "$chart_name_version"
    printf "%-14s %s\n" "App Version:" "$app_version"
    echo "--------------------------------------------------------------------------------"
    echo "Dependency Tree:"

    # Get release revision
    history_output=$(helm history "$name" --namespace "$namespace" -o json 2>&1)
    if ! echo "$history_output" | jq . &>/dev/null; then
        print_error "Could not get history for release '$name'." "Error from helm:\n$history_output"
        continue
    fi

    release_version=$(echo "$history_output" | jq '.[-1].revision')
    if [[ -z "$release_version" || "$release_version" == "null" ]]; then
        print_error "Could not determine release version for '$name'."
        continue
    fi

    # Get release data from Kubernetes secret
    secret_name="sh.helm.release.v1.${name}.v${release_version}"
    encoded_release_data=$(kubectl get secret "$secret_name" --namespace "$namespace" -o jsonpath='{.data.release}' 2>&1)
    if [[ $? -ne 0 ]]; then
        print_error "Could not retrieve secret for release '$name'." "Error from kubectl:\n$encoded_release_data"
        continue
    fi

    # Decode Helm release data (base64 + possibly gzip)
    decoded_once=$(echo "$encoded_release_data" | base64 -d 2>/dev/null)
    if [[ -z "$decoded_once" ]]; then
        print_error "Could not base64 decode secret '$secret_name'."
        continue
    fi

    # Handle different Helm storage formats
    inner_data=$(echo "$decoded_once" | jq -r .release 2>/dev/null || echo "$decoded_once")
    release_data_json=$(echo "$inner_data" | base64 -d 2>/dev/null | gunzip 2>/dev/null || echo "$inner_data" | base64 -d 2>/dev/null)

    if [[ -z "$release_data_json" ]]; then
        print_error "Could not decode or decompress release data for '$name'."
        continue
    fi

    # Extract dependencies from either Chart.lock or Chart.yaml
    dependencies=$(echo "$release_data_json" | jq '.chart.lock.dependencies // .chart.metadata.dependencies')
    if [[ "$dependencies" == "null" || "$(echo "$dependencies" | jq 'if type == "array" then length else 0 end')" -eq 0 ]]; then
        echo "  No dependencies found."
    else
        # Print dependency table header
        echo "  $chart_name_version"
        printf "    %-30s %-20s %s\n" "NAME" "VERSION" "REPOSITORY"

        # Process each dependency
        dep_count=$(echo "$dependencies" | jq 'length')
        current=0

        # Extract all dependencies including alias information
        echo "$dependencies" | jq -r '.[] | "\(.name)\t\(.version)\t\(.repository)\t\(.alias // "")"' | \
        while IFS=$'\t' read -r name version repo alias; do
            current=$((current+1))

            # Format with tree characters
            tree_char="├──"
            [[ "$current" -eq "$dep_count" ]] && tree_char="└──"

            printf "    %s %-28s %-20s %s\n" "$tree_char" "$name" "$version" "$repo"

            # Recurse into dependencies if enabled, use real name not alias
            [[ "$RECURSIVE_LOOKUP" == "true" ]] && resolve_dependencies "$name" "$version" "$repo" 2 "true"
        done
    fi
    echo
done

echo "================================================================================"
echo "Done."
