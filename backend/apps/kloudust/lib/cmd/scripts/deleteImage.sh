#!/bin/bash

# Params
# {1} Local cached image name; will be cached to /kloudust/catalog/{2}

CACHED_NAME="{1}"

function exitFailed() {
    echo Failed
    exit 1
}

printf "Deleting image from the catalog\n"
if ! sudo rm -f "/kloudust/catalog/$CACHED_NAME"; then exitFailed; fi    # -f: on shared storage another host deleted it already

printf "\n\nImage deleted successfully\n"
exit 0