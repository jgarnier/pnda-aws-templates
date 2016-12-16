#!/bin/bash -v

# This script runs on all instances except the saltmaster
# It installs a salt minion and mounts the disks

# The pnda_env-<cluster_name>.sh script generated by the CLI should
# be run prior to running this script to define various environment
# variables

set -e

apt-get update
apt-get -y install xfsprogs

# Mount the log volume, this is always xvdc
if [ -b /dev/xvdc ];
then
   echo "Mounting xvdc for logs"
   umount /dev/xvdc || echo 'not mounted'
   mkfs.xfs -f /dev/xvdc
   mkdir -p /var/log/panda
   sed -i "/xvdc/d" /etc/fstab
   echo "/dev/xvdc /var/log/panda auto defaults,nobootwait,comment=cloudconfig 0 2" >> /etc/fstab
fi
# Mount the other log volumes if they exist, up to 3 more may be mounted but this list could be extended if required
DISKS="xvdd xvde xvdf"
DISK_IDX=0
for DISK in $DISKS; do
   echo $DISK
   if [ -b /dev/$DISK ];
   then
      echo "Mounting $DISK"
      umount /dev/$DISK || echo 'not mounted'
      mkfs.xfs -f /dev/$DISK
      mkdir -p /data$DISK_IDX
      sed -i "/$DISK/d" /etc/fstab
      echo "/dev/$DISK /data$DISK_IDX auto defaults,nobootwait,comment=cloudconfig 0 2" >> /etc/fstab
      DISK_IDX=$((DISK_IDX+1))
   fi
done
cat /etc/fstab
mount -a

# Install the salt minion
export DEBIAN_FRONTEND=noninteractive
wget -O install_salt.sh https://bootstrap.saltstack.com
sh install_salt.sh -D -U stable 2016.11.1

# Set the master address the minion will register itself with
cat > /etc/salt/minion <<EOF
master: $PNDA_SALTMASTER_IP
EOF

# Set the grains common to all minions
cat >> /etc/salt/grains <<EOF
pnda:
  flavor: $PNDA_FLAVOR

pnda_cluster: $PNDA_CLUSTER 
EOF
