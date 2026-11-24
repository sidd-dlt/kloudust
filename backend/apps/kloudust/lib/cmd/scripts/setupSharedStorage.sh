#!/bin/bash

# Mounts the cloud's shared storage (NAS) at /kloudust/shared - every Kloudust host mounts the same
# storage at the same path - and moves the shared Kloudust resources (disks, metadata, snapshots,
# catalog, recyclebin) onto it. /kloudust/<dir> stays a symlink, so all other scripts keep working.
# Running VMs are not stopped, their disks are moved live using virsh blockcopy. Local files are deleted
# once copied. Safe to re-run, already moved resources are skipped.
#
# Params
# {1} Storage type - nfs or cifs
# {2} Storage server IP or DNS
# {3} NFS export path or CIFS share name
# {4} CIFS user ID (CIFS only)
# {5} CIFS password, base64 encoded (CIFS only)

NAS_TYPE="{1}"
NAS_ADDRESS="{2}"
NAS_PATH="{3}"
NAS_USER="{4}"
NAS_PASSWORD_B64="{5}"
SHARED=/kloudust/shared
SHARED_DIRS="catalog disks metadata snapshots recyclebin"
CIFS_CREDS=/etc/kloudust/nas.cred
EPOCH=`date +%s`
if [ -f "`which yum 2>/dev/null`" ]; then KVM_GROUP=qemu; else KVM_GROUP=libvirt; fi

function exitFailed() {
    echo Error: $1
    echo Failed
    exit 1
}

# Local copies of a shared folder: /kloudust/local/<dir>, or /kloudust/local/<dir>.premigration which is a real
# /kloudust/<dir> folder from an older layout, renamed so the symlink can take its place
function localCopiesOf() {
    for C in /kloudust/local/$1 /kloudust/local/$1.premigration; do if [ -d $C ]; then echo $C; fi; done
}

# Points /kloudust/$1 to $SHARED/$1. Done before any data is copied, so anything starting during the move
# (eg a VM) uses the shared copy, or fails if it isn't there yet, but never uses a stale local copy.
function linkDirToShared() {
    local LINK=/kloudust/$1 TARGET=$SHARED/$1
    if ! sudo mkdir -p $TARGET; then exitFailed "Unable to create $TARGET."; fi
    if getent group $KVM_GROUP > /dev/null; then sudo chgrp $KVM_GROUP $TARGET; fi
    if [ -d "$LINK" ] && [ ! -L "$LINK" ]; then     # running VMs keep their open files across the rename
        if [ -e /kloudust/local/$1.premigration ]; then exitFailed "Both $LINK and /kloudust/local/$1.premigration exist, merge them first."; fi
        if ! sudo mkdir -p /kloudust/local || ! sudo mv "$LINK" /kloudust/local/$1.premigration; then exitFailed "Unable to move $LINK aside."; fi
    fi
    if [ "`readlink -f $LINK`" != "$TARGET" ]; then
        if ! sudo ln -sfn $TARGET $LINK.kdnew || ! sudo mv -T $LINK.kdnew $LINK; then exitFailed "Unable to link $LINK to $TARGET."; fi
    fi
}

# Moves the local copies of /kloudust/$1 to $SHARED/$1, except the files named in $2 (disks running VMs still use)
function copyLocalToShared() {
    local TARGET=$SHARED/$1 KEEP="$2" EXCLUDES=`mktemp`
    echo "$KEEP" > $EXCLUDES
    for SRC in `localCopiesOf $1`; do
        # rsync checks each file and renames it into place only when complete, then deletes the local file
        if ! sudo rsync -a --ignore-existing --remove-source-files --exclude-from=$EXCLUDES "$SRC/" "$TARGET/"; then
            rm -f $EXCLUDES; exitFailed "Unable to copy $SRC to $TARGET, files not yet copied are still in $SRC."; fi
        # what's left was already on the shared storage (names are unique across the cloud) or is in use
        for F in `sudo find "$SRC" -type f`; do
            if ! grep -qxF "`basename "$F"`" <<< "$KEEP"; then sudo rm -f "$F"; fi
        done
        sudo find "$SRC" -depth -type d -empty -delete
    done
    rm -f $EXCLUDES
}


printf "Checking storage client software\n"    # installed by addHost.sh, hosts added before need it installed by hand
if [ "$NAS_TYPE" == "cifs" ]; then MOUNT_HELPER=mount.cifs; else MOUNT_HELPER=mount.nfs; fi
for C in $MOUNT_HELPER rsync; do
    if ! PATH=$PATH:/sbin:/usr/sbin command -v $C > /dev/null; then
        exitFailed "$C is missing, install nfs-utils (RHEL) or nfs-common (Ubuntu), cifs-utils and rsync on this host."; fi
done


printf "\n\nMounting the shared storage at $SHARED\n"
if ! sudo mkdir -p $SHARED /kloudust/local; then exitFailed "Unable to create $SHARED."; fi
if [ "$NAS_TYPE" == "cifs" ]; then
    if ! sudo mkdir -p `dirname $CIFS_CREDS` || ! sudo install -m 600 /dev/null $CIFS_CREDS; then exitFailed "Unable to create $CIFS_CREDS."; fi
    if ! printf "username=%s\npassword=%s\n" "$NAS_USER" "`echo "$NAS_PASSWORD_B64" | base64 -d`" | sudo tee $CIFS_CREDS > /dev/null; then
        exitFailed "Unable to write $CIFS_CREDS."; fi
    # shortcut: noperm skips client side permission checks as libvirt can't chown on CIFS, any local user on the host
    # can read the VM disks. Upgrade to NFS, or CIFS with unix extensions, if hosts are not dedicated to Kloudust.
    FSTAB_LINE="//$NAS_ADDRESS/$NAS_PATH $SHARED cifs credentials=$CIFS_CREDS,vers=3.0,noperm,file_mode=0660,dir_mode=0770,_netdev,nofail 0 0"
else
    # NFS v4.1 has working byte range locks, which virtlockd needs to stop two hosts running the same VM
    FSTAB_LINE="$NAS_ADDRESS:$NAS_PATH $SHARED nfs vers=4.1,hard,_netdev,nofail 0 0"
fi
if ! sudo sed -i "\| $SHARED |d" /etc/fstab || ! echo "$FSTAB_LINE" | sudo tee -a /etc/fstab > /dev/null; then exitFailed "Unable to update /etc/fstab."; fi
sudo systemctl daemon-reload
if ! mountpoint -q $SHARED && ! sudo mount $SHARED; then exitFailed "Unable to mount the shared storage."; fi
if ! mountpoint -q $SHARED; then exitFailed "Shared storage is not mounted at $SHARED."; fi

TESTFILE=$SHARED/.kdwritetest_`hostname`_$EPOCH
if ! sudo touch $TESTFILE; then exitFailed "Root can't write to the shared storage. Export NFS with no_root_squash or check the CIFS user's rights."; fi
if [ "$NAS_TYPE" == "nfs" ] && ! sudo chown 0:1 $TESTFILE; then
    sudo rm -f $TESTFILE; exitFailed "Root can't change ownership on the NFS export, libvirt needs it. Export it with no_root_squash."; fi
sudo rm -f $TESTFILE
# Identifies the storage, hosts with the same ID share disks (used by live migration to skip copying disks)
if [ ! -f $SHARED/.kloudust_storage_id ] && ! cat /proc/sys/kernel/random/uuid | sudo tee $SHARED/.kloudust_storage_id > /dev/null; then
    exitFailed "Unable to write the storage ID."; fi

if command -v selinuxenabled > /dev/null && selinuxenabled; then
    if [ "$NAS_TYPE" == "cifs" ]; then SEBOOL=virt_use_samba; else SEBOOL=virt_use_nfs; fi
    if ! sudo setsebool -P $SEBOOL 1; then exitFailed "Unable to allow VMs on shared storage in SELinux."; fi
fi


printf "\n\nMaking the hypervisor wait for the shared storage on boot\n"
if ! sudo mkdir -p /etc/systemd/system/libvirtd.service.d; then exitFailed; fi
if ! printf "[Unit]\nRequiresMountsFor=$SHARED\n" | sudo tee /etc/systemd/system/libvirtd.service.d/kloudust-shared.conf > /dev/null; then exitFailed; fi
if ! sudo systemctl daemon-reload; then exitFailed; fi


if command -v virsh > /dev/null; then    # an existing hypervisor, a new host gets this from addHost.sh
    if ! sudo grep -qE '^\s*lock_manager\s*=\s*"lockd"' /etc/libvirt/qemu.conf; then
        echo "WARNING!! virtlockd was not enabled on this host, enabling it now. These running VMs hold no disk lock until they are restarted: `sudo virsh list --name | xargs`"
        if ! echo 'lock_manager = "lockd"' | sudo tee -a /etc/libvirt/qemu.conf > /dev/null; then exitFailed "Unable to enable virtlockd."; fi
        if ! sudo systemctl enable --now virtlockd.socket; then exitFailed "Unable to enable virtlockd."; fi
        if ! sudo systemctl restart libvirtd; then exitFailed "Unable to restart libvirtd."; fi  # running VMs are not affected
    fi

fi


printf "\n\nPointing the shared Kloudust folders to the shared storage\n"
for D in $SHARED_DIRS; do linkDirToShared $D; done

# listed after the swap, a VM starting from now on opens the shared path, so its local disk is never in use
RUNNING_DISKS=""
if command -v virsh > /dev/null; then for VM in `sudo virsh list --name`; do
    RUNNING_DISKS="$RUNNING_DISKS
`sudo virsh domblklist $VM --details | awk -v s="$SHARED/" '$2=="disk" && index($4,s)!=1 {n=split($4,p,"/"); print p[n]}'`"
done; fi

printf "\n\nMoving the shared resources to the shared storage\n"
for D in $SHARED_DIRS; do
    if [ "$D" == "disks" ]; then copyLocalToShared $D "$RUNNING_DISKS"; else copyLocalToShared $D; fi
done


if command -v virsh > /dev/null; then
    printf "\n\nMoving disks of running VMs live to the shared storage\n"
    for VM in `sudo virsh list --name`; do
        QEMU_PID=`sudo cat /run/libvirt/qemu/$VM.pid` || exitFailed "Unable to find the QEMU process of $VM."
        while read T F; do
            if [[ "$F" == $SHARED/* ]]; then continue; fi    # already moved
            if [[ "$F" != /kloudust/disks/* ]] && [[ "$F" != /kloudust/local/disks/* ]]; then continue; fi
            B=`basename "$F"`; DEST=$SHARED/disks/$B
            # move only disks QEMU has open from a local copy, a VM started after the swap already runs from $DEST
            if ! sudo find /proc/$QEMU_PID/fd -lname "`readlink -f /kloudust/local`/disks*/$B*" | grep -q .; then continue; fi
            if sudo virsh blockjob $VM $T --info 2>/dev/null | grep -q "Block Copy"; then
                echo Cancelling the disk copy of $VM $T left over from an interrupted run
                if ! sudo virsh blockjob $VM $T --abort; then exitFailed "Unable to cancel the old disk copy of $VM $T."; fi
            fi
            echo Moving $VM disk $F to $DEST
            sudo rm -f "$DEST"    # partial copy from an interrupted run, the VM still uses its local disk
            if ! sudo virsh blockcopy $VM $T --dest "$DEST" --format qcow2 --wait --verbose --pivot --transient-job; then
                sudo rm -f "$DEST"; exitFailed "Live disk move failed for $VM disk $F, the VM is still running from its local disk."; fi
            for C in `localCopiesOf disks`; do sudo rm -f "$C/$B"; done     # stale now, the VM writes to $DEST
        done <<< "`sudo virsh domblklist $VM --details | awk '$2=="disk" {print $3, $4}'`"
        # blockcopy points the running VM at $SHARED/disks, keep its saved config on the stable /kloudust/disks path,
        # --security-info keeps its VNC password, the console needs it
        XMLFILE=`mktemp`
        if ! sudo virsh dumpxml --inactive --security-info $VM | sed "s|$SHARED/disks/|/kloudust/disks/|g" > $XMLFILE || ! sudo virsh define $XMLFILE; then
            rm -f $XMLFILE; exitFailed "Unable to update the saved config of $VM."; fi
        rm -f $XMLFILE
    done
    for C in `localCopiesOf disks`; do sudo find "$C" -depth -type d -empty -delete; done
fi
for D in $SHARED_DIRS; do for C in `localCopiesOf $D`; do echo "WARNING!! Files left in $C (a VM stopped during the move?), re-run to move them: `sudo ls -A $C | xargs`"; done; done


echo "KD_SHARED_STORAGE_SIZE=`df -B1 --output=size $SHARED | tail -n1 | tr -d ' '`"    # addHostStorage.js saves it as the host's disk size
printf "\n\nShared storage added successfully\n"
exit 0
