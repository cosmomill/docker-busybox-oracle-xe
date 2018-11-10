#!/bin/bash

# Install APEX

# set variables
APEX_VERSION="18.2"

echo "This script will install APEX $APEX_VERSION."

# check existence of input argument
if [ -z "$1" ]; then
	echo "Usage: $0 apex_$APEX_VERSION.zip"
	exit 1;
fi;

# check if absolute was entered
if [[ ! "$1" = /* ]]; then
	echo "Please specify an absolute path for $1."
	exit 1;
fi;

# check if file exists
if [ ! -f $1 ]; then
	echo "$1 does not exist."
	exit 1;
fi;

# download and extract APEX
unzip $1 -d /tmp
# "mv" doesn't work cause image directory is persistent (volume)
cp -r /tmp/apex $ORACLE_HOME
rm -rf /tmp/apex
rm -f $1
chown -R oracle:dba $ORACLE_HOME/apex
chmod 755 $ORACLE_HOME/apex
find $ORACLE_HOME/apex -type d -exec chmod 755 {} \;

# create a new tablespace to act as the default tablespace for APEX
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  alter session set container = XEPDB1;
  create tablespace APEX datafile '$ORACLE_BASE/oradata/$ORACLE_SID/apex.dbf' size 10m autoextend on next 1m maxsize unlimited;
  exit;
EOF"

cd $ORACLE_HOME/apex
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  alter session set container = XEPDB1;
  @apexins.sql APEX APEX TEMP /i/
  exit;
EOF"

# now scan for ORA errors or compilation errors
echo
echo "If there are ORA errors or compilation errors you will find them below!"
echo

grep ORA- *.log
grep PLS- *.log

# APEX configurations
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  alter session set container = XEPDB1;
  -- enable ORDS as the print server so PDF printing works out of the box
  exec apex_instance_admin.set_parameter('PRINT_BIB_LICENSED', 'APEX_LISTENER');
  -- disable the default set of strong complexity rules for ADMIN password
  exec apex_instance_admin.set_parameter(p_parameter => 'STRONG_SITE_ADMIN_PASSWORD', p_value => 'N');
  -- exec apex_instance_admin.set_parameter(p_parameter => 'WORKSPACE_PROVISION_DEMO_OBJECTS', p_value => 'N');
  -- exec apex_instance_admin.set_parameter(p_parameter => 'WORKSPACE_WEBSHEET_OBJECTS', p_value => 'N');

  -- APEX SMTP setup
  -- exec apex_instance_admin.set_parameter(p_parameter => 'SMTP_HOST_ADDRESS', p_value => '');
  -- exec apex_instance_admin.set_parameter(p_parameter => 'SMTP_HOST_PORT', p_value => '');
  -- exec apex_instance_admin.set_parameter(p_parameter => 'SMTP_USERNAME', p_value => '');
  -- exec apex_instance_admin.set_parameter(p_parameter => 'SMTP_PASSWORD', p_value => '');
  -- exec apex_instance_admin.set_parameter(p_parameter => 'SMTP_TLS_MODE', p_value => 'Y');

  -- Oracle Wallet (required for SSL connections)
  -- exec apex_instance_admin.set_parameter(p_parameter => 'WALLET_PATH', p_value => '');
  -- exec apex_instance_admin.set_parameter(p_parameter => 'WALLET_PWD', p_value => '');
  exit;
EOF"

# need to remove the "HIDE" from the accept statement or else the << EOF1 doesn't work
sed -i 's/password \[\] " HIDE/password \[\] "/g' $ORACLE_HOME/apex/apxchpwd.sql

# set password and disable XDB HTTP and FTP listener
APEX_ADMIN_PWD=${APEX_ADMIN_PWD:-"`tr -dc A-Za-z0-9 < /dev/urandom | head -c8`"}
APEX_ADMIN_PWD_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.apex_admin.passwd
echo -n $APEX_ADMIN_PWD > $APEX_ADMIN_PWD_FILE
chmod 600 $APEX_ADMIN_PWD_FILE
chown root:root $APEX_ADMIN_PWD_FILE

# make sure no indents
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
alter session set container = XEPDB1;
@apxconf.sql
ADMIN
ADMIN
$APEX_ADMIN_PWD
0
EOF"

# anonymous user is not needed when we don't use XDB
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  alter session set container = XEPDB1;
  exec dbms_xdb.setftpport(0);
  alter user ANONYMOUS account lock;
  exit;
EOF"

# configure RESTful Services
APEX_LISTENER_PWD=${APEX_LISTENER_PWD:-"`tr -dc A-Za-z0-9 < /dev/urandom | head -c8`"}
APEX_LISTENER_PWD_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.apex_listener.passwd
echo -n $APEX_LISTENER_PWD > $APEX_LISTENER_PWD_FILE
chmod 600 $APEX_LISTENER_PWD_FILE
chown root:root $APEX_LISTENER_PWD_FILE

APEX_REST_PUBLIC_USER_PWD=${APEX_REST_PUBLIC_USER_PWD:-"`tr -dc A-Za-z0-9 < /dev/urandom | head -c8`"}
APEX_REST_PUBLIC_USER_PWD_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.apex_rest_public_user.passwd
echo -n $APEX_REST_PUBLIC_USER_PWD > $APEX_REST_PUBLIC_USER_PWD_FILE
chmod 600 $APEX_REST_PUBLIC_USER_PWD_FILE
chown root:root $APEX_REST_PUBLIC_USER_PWD_FILE

su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  alter session set container = XEPDB1;
  @apex_rest_config_core.sql @ $APEX_LISTENER_PWD $APEX_REST_PUBLIC_USER_PWD
  exit;
EOF"

# now scan for ORA errors or compilation errors
echo
echo "If there are ORA errors or compilation errors you will find them below!"
echo

grep ORA- *.log
grep PLS- *.log

# Oracle’s advice for the APEX_PUBLIC_USER is to set the PASSWORD_LIFE_TIME to UNLIMITED.
# To do this we have to create a new profile.
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  alter session set container = XEPDB1;
  create profile APEX_PUBLIC limit
    failed_login_attempts 10
    password_life_time unlimited
    password_reuse_time unlimited
    password_reuse_max unlimited
    password_lock_time 1
    composite_limit unlimited
    sessions_per_user unlimited
    cpu_per_session unlimited
    cpu_per_call unlimited
    logical_reads_per_session unlimited
    logical_reads_per_call unlimited
    idle_time unlimited
    connect_time unlimited
    private_sga unlimited;
  exit;
EOF"

# next, we assign this profile to APEX_LISTENER, APEX_REST_PUBLIC_USER
su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
  alter session set container = XEPDB1;
  alter user APEX_LISTENER profile APEX_PUBLIC;
  alter user APEX_REST_PUBLIC_USER profile APEX_PUBLIC;
  exit;
EOF"

# remember the installed APEX version
APEX_UPDATE_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.apex_version
echo -n $APEX_VERSION > $APEX_UPDATE_FILE
chmod 600 $APEX_UPDATE_FILE
chown root:root $APEX_UPDATE_FILE