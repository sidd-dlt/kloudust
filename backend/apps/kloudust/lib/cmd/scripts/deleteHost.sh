#!/bin/bash

# Kills the host completely. Kloudust equivalent of rm -rf /
# BE VERY CAREFUL (or frankly NEVER call this script).

virsh list --all --name > doms.txt  # every VM listed
cat doms.txt | xargs -n 1 virsh destroy # every VM destroyed
cat doms.txt | xargs -n 1 virsh undefine # every VM undefined

# The shared storage belongs to all hosts, unmount it before wiping, never delete through it
sed -i "\| /kloudust/shared |d" /etc/fstab
rm -f /etc/systemd/system/libvirtd.service.d/kloudust-shared.conf /etc/kloudust/nas.cred
if mountpoint -q /kloudust/shared && ! umount /kloudust/shared && ! umount -l /kloudust/shared; then
    echo "Unable to unmount /kloudust/shared, not deleting /kloudust"; exit 0
fi
if mountpoint -q /kloudust/shared; then echo "/kloudust/shared still mounted, not deleting /kloudust"; exit 0; fi
rm -rf /kloudust    # all Kloudust data on this host gone
exit 0              # always successful