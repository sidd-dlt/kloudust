#!/bin/bash

# Params
# {1} - Domain / VM name
# {2} - The IP for the host to migrate to
# {3} - The host to migrate to admin ID
# {4} - The host to migrate to admin password

DOMAIN="{1}"
HOSTTO="{2}"
HOSTTOID="{3}"
HOSTTOPW='{4}'
HOSTTOHOSTKEY='{5}'
HOSTTOPORT='{6}'

remoteSSH() {
    sshpass -p "$HOSTTOPW" ssh -o StrictHostKeyChecking=accept-new -p "$HOSTTOPORT" "$HOSTTOID@$HOSTTO" "$@"
}

remoteSCPTo() {
    sshpass -p "$HOSTTOPW" scp -p -P "$HOSTTOPORT" -o StrictHostKeyChecking=accept-new "$@"
}

function exitFailed() {
    echo Error: $1
    echo Failed
    exit 1
}

echo Setting up host-to networks paths
HOSTTOHOSTNAME=`remoteSSH hostname`
if [ -z $HOSTTOHOSTNAME ]; then exitFailed "Unable to detect hostname for the TO server"; fi
if ! cat /etc/hosts | grep $HOSTTOHOSTNAME; then
        echo "$HOSTTO $HOSTTOHOSTNAME" >> /etc/hosts
fi
echo Host to hostname detected and set as $HOSTTOHOSTNAME

# Hosts with the same storage ID mount the same shared storage, so the disks must not be copied (it'd copy onto itself)
STORAGE_ID_FILE=/kloudust/shared/.kloudust_storage_id
LOCAL_STORAGE_ID=`cat $STORAGE_ID_FILE 2>/dev/null`
REMOTE_STORAGE_ID=`remoteSSH "cat $STORAGE_ID_FILE 2>/dev/null"`
SHARED_STORAGE=false
if [ -n "$LOCAL_STORAGE_ID" ] && [ "$LOCAL_STORAGE_ID" == "$REMOTE_STORAGE_ID" ]; then
    SHARED_STORAGE=true
    echo KD_SHARED_STORAGE=true     # liveMigrate.js reads this
    echo Both hosts use the same shared storage, disks will not be copied
fi

mapfile -t DISKINFOS < <(virsh domblklist "$DOMAIN" | awk '/\.qcow2$/ {print $1 "|" $2}')

if [ ${#DISKINFOS[@]} -eq 0 ]; then exitFailed "Unable to detect disk files to migrate"; fi

DISKDEVICESTOMIGRATE=""

echo Disk information for the VM to migrate
for DISKINFO in "${DISKINFOS[@]}"; do
    DISKDEVICE=`echo "$DISKINFO" | cut -d"|" -f1`
    DISKTOMIGRATE=`echo "$DISKINFO" | cut -d"|" -f2`
    DISKSIZE=`virsh domblkinfo "$DOMAIN" "$DISKDEVICE" | grep -i Capacity | tr -s " " | cut -d" " -f2`
    DISKSIZEGB=`echo "$DISKSIZE / 1073741824" | bc`

    echo DISKDEVICE=$DISKDEVICE
    echo DISKTOMIGRATE=$DISKTOMIGRATE
    echo DISKSIZE=$DISKSIZE
    echo DISKSIZEGB=$DISKSIZEGB

    if [ -z "$DISKDEVICE" ]; then exitFailed "Unable to detect disk device to migrate"; fi
    if [ -z "$DISKTOMIGRATE" ]; then exitFailed "Unable to detect disk file to migrate"; fi
    if [ -z "$DISKSIZE" ]; then exitFailed "Unable to detect disk size to migrate for $DISKDEVICE"; fi
    if [ -z "$DISKSIZEGB" ]; then exitFailed "Unable to detect disk size in GB to migrate for $DISKDEVICE"; fi

    if [ "$SHARED_STORAGE" == "true" ]; then continue; fi
    if remoteSSH "test -e \"$DISKTOMIGRATE\""; then exitFailed "Disk $DISKTOMIGRATE already exists on the destination, not overwriting it."; fi
    echo Creating remote migration disk $DISKTOMIGRATE
    if ! remoteSSH "qemu-img create -f qcow2 \"$DISKTOMIGRATE\" \"${DISKSIZEGB}G\""; then
        exitFailed "Migration disk creation failed for $DISKTOMIGRATE."
    fi

    if [ -z "$DISKDEVICESTOMIGRATE" ]; then
        DISKDEVICESTOMIGRATE="$DISKDEVICE"
    else
        DISKDEVICESTOMIGRATE="$DISKDEVICESTOMIGRATE,$DISKDEVICE"
    fi
done

echo DISKDEVICESTOMIGRATE=$DISKDEVICESTOMIGRATE
STORAGE_MIGRATION_ARGS="--copy-storage-all --migrate-disks $DISKDEVICESTOMIGRATE"
if [ "$SHARED_STORAGE" == "true" ]; then STORAGE_MIGRATION_ARGS="--undefinesource"; fi  # the old host must not keep a definition using the same disks
CDROMDEVICE=`virsh domblklist $DOMAIN | grep cloudinit.iso | tr -s " " | xargs | cut -d" " -f1`
if [ $CDROMDEVICE ]; then 
    echo Cloudinit CDROM detect at device $CDROMDEVICE. Ejecting.
    if ! virsh change-media $DOMAIN $CDROMDEVICE --eject; then exitFailed "Cloudinit CDROM detected and failed to eject."; fi
fi

echo Starting $DOMAIN Live Migration
if ! sshpass -p "$HOSTTOPW" virsh migrate --verbose --live --unsafe --persistent $STORAGE_MIGRATION_ARGS --migrateuri "tcp://$HOSTTO" "$DOMAIN" "qemu+ssh://$HOSTTO:$HOSTTOPORT/system?no_verify=1"; then
    exitFailed "VM migration failed." 
fi

if [ ! -f "/kloudust/metadata/$DOMAIN.metadata" ]; then exitFailed "Unable to locate VM metadata."; fi
if [ "$SHARED_STORAGE" != "true" ]; then    # on shared storage it is the same file, copying would truncate it
    echo Copying VM metadata
    if ! remoteSCPTo "/kloudust/metadata/$DOMAIN.metadata" "$HOSTTOID@$HOSTTO:/kloudust/metadata/$DOMAIN.metadata"; then
        exitFailed "Unable to copy VM metadata."
    fi
fi

echo Dumping fresh VM XML on destination
if ! remoteSSH "virsh dumpxml $DOMAIN > /kloudust/metadata/$DOMAIN.xml"; then
    exitFailed "Unable to create VM XML on destination."
fi

# Copy firewall scripts on destination
FIREWALL_SCRIPT=0
for FW_SCRIPT in /kloudust/system/firewall/fw_${DOMAIN}_*.sh; do
    [ -f "$FW_SCRIPT" ] || continue
    FIREWALL_SCRIPT=1

    echo Copying firewall script $FW_SCRIPT
    if ! remoteSCPTo "$FW_SCRIPT" "$HOSTTOID@$HOSTTO:$FW_SCRIPT"; then
        exitFailed "Unable to copy firewall script $FW_SCRIPT."
    fi
done

# Reapply firewall on destination
if [ "$FIREWALL_SCRIPT" = "1" ]; then
    echo Reapplying firewall on destination
    if ! remoteSSH "for FW_SCRIPT in /kloudust/system/firewall/fw_${DOMAIN}_*.sh; do [ -f \"\$FW_SCRIPT\" ] || continue; /bin/bash \"\$FW_SCRIPT\" || exit 1; done"; then
        exitFailed "Unable to reapply firewall on destination."
    fi
fi

# On shared storage liveMigrate.js does not run deleteVM on this host (it would recycle the shared disks), clean up here
if [ "$SHARED_STORAGE" == "true" ]; then rm -f /kloudust/system/firewall/fw_${DOMAIN}_*.sh; fi

printf "\n\nVM migrated successfully\n"
exit 0