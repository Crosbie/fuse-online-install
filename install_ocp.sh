#!/bin/bash

# ====================================================
# Standalone script for deploying syndesis on OCP (including imagestreams)
#

# ================
# Tag updated by release script
TAG=1.3.10
# ================

ARGS="$@"
set -o pipefail
set -eu

display_usage() {
  cat <<EOT
Syndesis Installation Tool for OCP

Usage: syndesis-install [options]

with options:

-r --route <host>            The route to install
-c --console <console-url>   The URL to the openshift console
-p --project <project>       Install into this project. The project will be deleted
                             if it already exists. By default, install into the current
                             project (without deleting)
-i --is-namespace            Namespace in to which to install the imagestreams.
                             By default in the same project as Fuse Ignite itself
-w --watch                   Wait until the installation has completed
-o --open                    Open Syndesis after installation (implies --watch)
   --help                    This help message
-v --verbose                 Verbose logging
EOT
}

# ============================================================
# Helper functions taken over from "syndesis" CLI:

recreate_project() {
    local project=$1
    local dont_ask=${2:-false}

    if [ -z "$project" ]; then
        echo "No project given"
        exit 1
    fi

    # Delete project if existing
    if oc get project "${project}" >/dev/null 2>&1 ; then
        if [ $dont_ask != "true" ]; then
            echo =============== WARNING -- Going to delete project ${project}
            oc get all -n $project
            echo ============================================================
            read -p "Do you really want to delete the existing project $project ? yes/[no] : " choice
            echo
            if [ "$choice" != "yes" ] && [ "$choice" != "y" ]; then
                echo "Aborting on user's request"
                exit 1
            fi
        fi
        echo "Deleting project ${project}"
        oc delete project "${project}"
    fi

    # Create project afresh
    echo "Creating project ${project}"
    for i in {1..10}; do
        if oc new-project "${project}" >/dev/null 2>&1 ; then
            break
        fi
        echo "Project still exists. Sleeping 10s ..."
        sleep 10
    done
    oc project "${project}"
}

create_oauthclient() {
    create_openshift_resource "serviceaccount-as-oauthclient-restricted.yml"
}

create_imagestreams() {
    create_openshift_resource "fuse-ignite-image-streams.yml" "$(readopt --is-namespace -i)"
}

create_and_apply_template() {
    local route=$1
    local console=${2:-}

    if [ -z "$route" ]; then
        echo "No route given"
        exit 1
    fi

    create_openshift_resource "fuse-ignite-ocp.yml"

    local is_namespace=$(readopt -i --is-namespace)
    if [ -z "$is_namespace" ]; then
        is_namespace="$(oc project -q)"
    fi

    oc new-app --template "fuse-ignite"\
      -p ROUTE_HOSTNAME="${route}" \
      -p OPENSHIFT_CONSOLE_URL="$console" \
      -p OPENSHIFT_MASTER="$(oc whoami --show-server)" \
      -p OPENSHIFT_PROJECT="$(oc project -q)" \
      -p OPENSHIFT_OAUTH_CLIENT_SECRET=$(oc sa get-token syndesis-oauth-client) \
      -p IMAGE_STREAM_NAMESPACE="$is_namespace"
}

guess_route() {
    local project=${1:-}
    if [ -z "${project}" ]; then
        project=$(oc project -q)
    fi
    local log=$(oc create service clusterip smokeservice --tcp=4343 2>&1 && \
                oc create route edge --service=smokeservice 2>&1)
    if [ $? != 0 ]; then
        echo "ERROR: Cannot create pivot route\n$log"
        exit 1
    fi
    local domain=$(oc get route smokeservice -o template  --template='{{.spec.host}}' 2>&1)
    if [ $? != 0 ]; then
        echo "ERROR: Cannot extract route: $domain"
        exit 1
    fi
    log=$(oc delete service smokeservice 2>&1 && \
          oc delete route smokeservice 2>&1)
    if [ $? != 0 ]; then
        echo "ERROR: Cannot delete pivot route\n$log"
        exit 1
    fi
    echo "${project}.${domain#*.}"
}

create_openshift_resource() {
    local resource=${1}
    local ns="${2:-}"
    local extra_args=''
    if [ -n "${ns}" ]; then
        extra_args="--namespace $ns"
    fi
    oc create $extra_args -f https://raw.githubusercontent.com/syndesisio/fuse-ignite-install/${TAG}/resources/${resource}
}

wait_for_syndesis_to_be_ready() {
    # Wait a bit to start image fetching
    oc get pods -w &
    watch_pid=$!
    for dc in "syndesis-server" "syndesis-ui" "syndesis-meta"; do
        echo "Waiting for $dc to be started"
        local replicas="$(oc get dc $dc -o jsonpath='{.status.availableReplicas}')"
        while [ "$replicas" -lt 1 ]; do
            echo "Sleeping 10s ..."
            sleep 10
            replicas=$(oc get dc $dc -o jsonpath="{.status.availableReplicas}")
        done
    done
    kill $watch_pid
}

probe_commands() {
    for cmd in $@; do
      local ret=$(which $cmd 2>/dev/null)
      if [ $? -eq 0 ]; then
          echo $ret
          return
      fi
    done
}

open_url() {
    local url=$1
    local cmd="$(probe_commands open xdg-open chrome firefox)"
    if [ -z "$cmd" ]; then
        echo "Cannot find command for opening URL:"
        echo $url
        exit 1
    fi
    exec $cmd $url
}

# Checks if a flag is present in the arguments.
hasflag() {
    filters="$@"
    for var in $ARGS; do
        for filter in $filters; do
          if [ "$var" = "$filter" ]; then
              echo 'true'
              return
          fi
        done
    done
}

# Read the value of an option.
readopt() {
    filters="$@"
    next=false
    for var in $ARGS; do
        if $next; then
            echo $var
            break;
        fi
        for filter in $filters; do
            if [[ "$var" = ${filter}* ]]; then
                local value="${var//${filter}=/}"
                if [ "$value" != "$var" ]; then
                    echo $value
                    return
                fi
                next=true
            fi
        done
    done
}

check_error() {
    local msg="$*"
    if [ "${msg//ERROR/}" != "${msg}" ]; then
        echo $msg
        exit 1
    fi
}

# ==============================================================

if [ $(hasflag --verbose -v) ]; then
    export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
    set -x
fi

# Main code
if [ $(hasflag --help -h) ]; then
    display_usage
    exit 0
fi

set +e
which oc &>/dev/null
if [ $? -ne 0 ]; then
    echo The oc binary needs to be available on '$PATH'
    echo
    echo The easiest way to download the CLI is by accessing the About page on
    echo the web console if your cluster administrator has enabled the download
    echo links.
    exit 1
fi

# Console (if given)
console=$(readopt --console)

# If a project is given, create it new or recreate it
project=$(readopt --project -p)
if [ -n "${project}" ]; then
    recreate_project $project
else
    project=$(oc project -q)
fi

# Get route
route=$(readopt --route)
if [ -z "${route}" ]; then
    route="$(guess_route "$project")"
    check_error $route
fi

# Required OAuthclient
create_oauthclient

# Create image streams
create_imagestreams

# Apply a template, based on the given arguments
create_and_apply_template "$route" "$console"

if [ $(hasflag --watch -w) ] || [ $(hasflag --open -o) ]; then
    wait_for_syndesis_to_be_ready
fi

cat <<EOT
========================================================
Congratulation, Fuse Ignite ($TAG) has been installed successfully !
Open now your browser at the following URL:

https://$route

Enjoy !
EOT

if [ $(hasflag --open -o) ]; then
    open_url "https://$route"
fi
