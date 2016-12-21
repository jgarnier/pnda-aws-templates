#!/bin/bash -v

# This script runs on instances with a node_type tag of "cdh-mgr"
# It sets the roles that determine what software is installed
# on this instance by platform-salt scripts and the minion
# id and hostname

# The pnda_env-<cluster_name>.sh script generated by the CLI should
# be run prior to running this script to define various environment
# variables
set -e

# The cloudera:role grain is used by the cm_setup.py (in platform-salt) script to
# place specific cloudera roles on this instance.
# The mapping of cloudera roles to cloudera:role grains is
# defined in the cfg_<flavor>.py.tpl files (in platform-salt)
cat >> /etc/salt/grains <<EOF
cloudera:
  role: MGR01
roles:
  - cloudera_namenode
  - oozie_database
  - mysql_connector
  - hue
  - opentsdb
  - grafana

EOF

cat >> /etc/salt/minion <<EOF
id: $PNDA_CLUSTER-cdh-mgr-1
EOF

echo $PNDA_CLUSTER-cdh-mgr-1 > /etc/hostname
hostname $PNDA_CLUSTER-cdh-mgr-1

service salt-minion restart
