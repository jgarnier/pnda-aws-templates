#!/bin/bash -v

# This script runs on instances with a node_type tag of "cdh-edge"
# The base.sh script does not run on this instance type
# It mounts the disks and installs a salt master

# The pnda_env-<cluster_name>.sh script generated by the CLI should
# be run prior to running this script to define various environment
# variables
set -ex

# Set up ssh access to the platform-salt git repo on the package server,
# if secure access is required this key will be used automatically.
# This mode is not normally used now the public github is available
chmod 400 /tmp/git.pem
echo "Host $PACKAGES_SERVER_IP" >> /root/.ssh/config
echo "  IdentityFile /tmp/git.pem" >> /root/.ssh/config
echo "  StrictHostKeyChecking no" >> /root/.ssh/config

apt-get update
apt-get -y install xfsprogs

# Mount the log volume this is always xvdc
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

# Install a saltmaster and minion, plus saltmaster config
apt-get -y install python-pip
apt-get -y install python-git
wget -O install_salt.sh https://bootstrap.saltstack.com
sh install_salt.sh -D -U -M stable 2015.8.11
apt-get -y install unzip

cat << EOF > /etc/salt/master
## specific PNDA saltmaster config
auto_accept: True      # auto accept minion key on new minion provisioning

fileserver_backend:
  - roots
  - minion

file_roots:
  base:
    - /srv/salt/platform-salt/salt

pillar_roots:
  base:
    - /srv/salt/platform-salt/pillar

# Do not merge top.sls files across multiple environments
top_file_merging_strategy: same

# To autoload new created modules, states add and remove salt keys,
# update bastion /etc/hosts file automatically ... add the following reactor configuration
reactor:
  - 'minion_start':
    - salt://reactor/sync_all.sls
  - 'salt/cloud/*/created':
    - salt://reactor/create_bastion_host_entry.sls
  - 'salt/cloud/*/destroying':
    - salt://reactor/delete_bastion_host_entry.sls
## end of specific PNDA saltmaster config
file_recv: True

failhard: True
EOF

# Set up platform-salt that contains the scripts the saltmaster runs to install software
mkdir -p /srv/salt
cd /srv/salt

if [ "x$PLATFORM_GIT_REPO_URI" != "x" ]; then
  git clone -q --branch $PLATFORM_GIT_BRANCH $PLATFORM_GIT_REPO_URI
elif [ "x$PLATFORM_URI" != "x" ] ; then
  mkdir -p /srv/salt/platform-salt && cd /srv/salt/platform-salt && \
  wget -q -O - $PLATFORM_URI | tar -zvxf - --strip=1 && ls -al && \
  cd -
elif [ "x$PLATFORM_SALT_LOCAL" != "x" ]; then
  tar zxf /tmp/$PLATFORM_SALT_TARBALL -C /srv/salt
else
  exit 2
fi

# Push pillar config into platform-salt for environment specific config
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
os_user: $OS_USER
keystone.user: ''
keystone.password: ''
keystone.tenant: ''
keystone.auth_url: ''
keystone.region_name: ''
aws.apps_region: '$PNDA_APPS_REGION'
aws.apps_key: '$PNDA_APPS_ACCESS_KEY_ID'
aws.apps_secret: '$PNDA_APPS_SECRET_ACCESS_KEY'
pnda.apps_container: '$PNDA_APPS_CONTAINER'
pnda.apps_folder: '$PNDA_APPS_FOLDER'
aws.archive_region: '$PNDA_APPS_REGION'
aws.archive_key: '$PNDA_APPS_ACCESS_KEY_ID'
aws.archive_secret: '$PNDA_APPS_SECRET_ACCESS_KEY'
pnda.archive_container: '$PNDA_ARCHIVE_CONTAINER'
pnda.archive_type: 's3a'
pnda.archive_service: ''
EOF

if [ "x$JAVA_MIRROR" != "x" ] ; then
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
java:
  source_url: '$JAVA_MIRROR'
EOF
fi

if [ "x$CLOUDERA_MIRROR" != "x" ] ; then
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
cloudera:
  parcel_repo: '$CLOUDERA_MIRROR'
EOF
fi

if [ "x$ANACONDA_MIRROR" != "x" ] ; then
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
anaconda:
  parcel_version: "4.0.0"
  parcel_repo: '$ANACONDA_MIRROR'
EOF
fi

if [ "x$NPM_REGISTRY" != "x" ] ; then
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
npm:
  registry: '$NPM_REGISTRY'
EOF
fi

if [ "x$PACKAGES_SERVER_URI" != "x" ] ; then
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
packages_server:
  base_uri: $PACKAGES_SERVER_URI
EOF
fi

if [ "$PR_FS_TYPE" == "swift" ] ; then
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
package_repository:
  fs_type: 'swift'
EOF
elif [ "$PR_FS_TYPE" == "s3" ] ; then
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
package_repository:
  fs_type: 's3'
EOF
elif [ "$PR_FS_TYPE" == "sshfs" ] ; then
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
package_repository:
  fs_type: "sshfs"
  fs_location_path: "$PR_FS_LOCATION_PATH"
  sshfs_user: "$PR_SSHFS_USER"
  sshfs_host: "$PR_SSHFS_HOST"
  sshfs_path: "$PR_SSHFS_PATH"
  sshfs_key: "$PR_SSHFS_KEY"
EOF
else
cat << EOF >> /srv/salt/platform-salt/pillar/env_parameters.sls
package_repository:
  fs_type: "$PR_FS_TYPE"
  fs_location_path: "$PR_FS_LOCATION_PATH"
EOF
fi

restart salt-master

# The cloudera:role grain is used by the cm_setup.py (in platform-salt) script to
# place specific cloudera roles on this instance.
# The mapping of cloudera roles to cloudera:role grains is
# defined in the cfg_<flavor>.py.tpl files (in platform-salt)
cat > /etc/salt/grains <<EOF
pnda:
  flavor: $PNDA_FLAVOR
cloudera:
  role: EDGE
roles:
  - cloudera_edge
  - console_frontend
  - console_backend_data_logger
  - console_backend_data_manager
  - graphite
  - gobblin
  - deployment_manager
  - package_repository
  - data_service
  - cloudera_manager
  - platform_testing_cdh
  - mysql_connector
  - jupyter
  - elk
  - logserver
  - kibana_dashboard
  - impala-shell
  - yarn-gateway
  - hbase_opentsdb_tables
  - hdfs_cleaner
  - master_dataset
  - pnda_restart

pnda_cluster: $PNDA_CLUSTER
EOF

cat >> /etc/salt/minion <<EOF
master: $PNDA_SALTMASTER_IP
id: $PNDA_CLUSTER-cdh-edge
EOF

echo $PNDA_CLUSTER-cdh-edge > /etc/hostname
hostname $PNDA_CLUSTER-cdh-edge

service salt-minion restart
