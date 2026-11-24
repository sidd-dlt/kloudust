#!/bin/bash

# Params
# {1} Download URI
# {2} Local cached image name; will be cached to /kloudust/catalog/{2}

URI="{1}"
CACHED_NAME="{2}"

function exitFailed() {
    echo Failed
    exit 1
}

printf "Adding image to catalog\n"
# download aside then rename, the catalog may be shared and another host may be caching the same image
TMP_NAME="/kloudust/catalog/$CACHED_NAME.kdtmp.$$"
if ! sudo bash -c "curl -L \"$URI\" > \"$TMP_NAME\"" || ! sudo mv -f "$TMP_NAME" "/kloudust/catalog/$CACHED_NAME"; then
    sudo rm -f "$TMP_NAME"; exitFailed; fi
if ! sudo ls -al "/kloudust/catalog/$CACHED_NAME"; then exitFailed; fi


printf "\n\nGiving KVM permissions to the image"
if [ -f "`which yum`" ]; then 
    if ! sudo chgrp qemu "/kloudust/catalog/$CACHED_NAME"; then exitFailed; fi
else 
    if ! sudo chgrp libvirt "/kloudust/catalog/$CACHED_NAME"; then exitFailed; fi
fi

printf "\n\nImage added successfully\n"
exit 0