#!/bin/bash

# move DB files
function moveFiles {
	if [ ! -d $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID ]; then
		mkdir -p $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	fi;

	mv $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv $ORACLE_HOME/dbs/orapw$ORACLE_SID $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv $ORACLE_HOME/network/admin/listener.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv /etc/sysconfig/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR.conf $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
	mv /etc/oratab $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/

	chown -R oracle:dba $ORACLE_BASE/oradata/dbconfig

	symLinkFiles;
}

# symbolic link DB files
function symLinkFiles {
	if [ ! -L $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora ]; then
		ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/spfile$ORACLE_SID.ora $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora
	fi;

	if [ ! -L $ORACLE_HOME/dbs/orapw$ORACLE_SID ]; then
		ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/orapw$ORACLE_SID $ORACLE_HOME/dbs/orapw$ORACLE_SID
	fi;

	if [ ! -L $ORACLE_HOME/network/admin/tnsnames.ora ]; then
		ln -sf $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora
	fi;

	if [ ! -L $ORACLE_HOME/network/admin/listener.ora ]; then
		ln -sf $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/listener.ora $ORACLE_HOME/network/admin/listener.ora
	fi;

	if [ ! -L /etc/sysconfig/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR.conf ]; then
		ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR.conf /etc/sysconfig/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR.conf
	fi;

	if [ ! -L /etc/oratab ]; then
		ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/oratab /etc/oratab
	fi;
}

# import oracle dumps
function impdp () {
	DUMP_FILE=$(basename "$1")
	DUMP_NAME=${DUMP_FILE%.dmp}

	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      -- create IMPDP user
      create user IMPDP identified by IMPDP;
      alter user IMPDP account unlock;
      grant DBA to IMPDP with admin option;
      -- create new scheme user
      create or replace directory IMPDP as '$DOCKER_BUILD_FOLDER/docker-entrypoint-initdb.d';
      create tablespace $DUMP_NAME datafile '$ORACLE_BASE/oradata/$ORACLE_SID/$DUMP_NAME.dbf' size 10m autoextend on next 1m maxsize unlimited;
      create user $DUMP_NAME
      identified by \"$DUMP_NAME\"
      default tablespace $DUMP_NAME
      temporary tablespace TEMP
      quota unlimited on $DUMP_NAME;
      alter user $DUMP_NAME default role all;
      grant connect, resource to $DUMP_NAME;
      exit;
EOF"

	su -s /bin/bash oracle -c "impdp IMPDP/IMPDP directory=IMPDP dumpfile=$DUMP_FILE nologfile=y"

	# disable IMPDP user
	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      ALTER USER IMPDP ACCOUNT LOCK;
      exit;
EOF"
}

# SIGTERM handler
function _term() {
	echo "Stopping container."
	echo "SIGTERM received, shutting down database!"
	/etc/init.d/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR stop
}

# SIGKILL handler
function _kill() {
	echo "SIGKILL received, shutting down database!"
	/etc/init.d/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR stop
}

# create DB
function createDB {
	# run root.sh
	$ORACLE_HOME/root.sh

	# auto generate SYSDBA password if not passed on
	SYSDBA_PWD=${SYSDBA_PWD:-"`tr -dc A-Za-z0-9 < /dev/urandom | head -c8`"}

	(echo $SYSDBA_PWD; echo $SYSDBA_PWD;) | /etc/init.d/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR configure

	# update tnsnames.ora to use localhost instead of the current hostname
	sed -i -r "s/\(HOST = [^)]+/\(HOST = localhost/" $ORACLE_HOME/network/admin/tnsnames.ora

	# update listener to listen on all addresses on the local machine
	sed -i -r "s/\(HOST = [^)]+/\(HOST = 0.0.0.0/" $ORACLE_HOME/network/admin/listener.ora
	echo "DEDICATED_THROUGH_BROKER_LISTENER=ON" >> $ORACLE_HOME/network/admin/listener.ora
	echo "DIAG_ADR_ENABLED=OFF" >> $ORACLE_HOME/network/admin/listener.ora

	# reread the listener.ora file
	lsnrctl reload

	# don't expire passwords
	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      alter profile default limit password_life_time unlimited;
      exit;
EOF"

	# move redo logs to mountable directory ($ORACLE_BASE/oradata)
	su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
      EXEC DBMS_XDB.SETLISTENERLOCALACCESS(FALSE);

      alter database add logfile group 4 ('$ORACLE_BASE/oradata/$ORACLE_SID/redo04.log') size 50m;
      alter database add logfile group 5 ('$ORACLE_BASE/oradata/$ORACLE_SID/redo05.log') size 50m;
      alter database add logfile group 6 ('$ORACLE_BASE/oradata/$ORACLE_SID/redo06.log') size 50m;
      alter system switch logfile;
      alter system switch logfile;
      alter system checkpoint;
      alter database drop logfile group 1;
      alter database drop logfile group 2;

      alter system set db_recovery_file_dest='';
      exit;
EOF"

	# move database operational files to oradata
	moveFiles;

	# store SYSDBA password 
	SYSDBA_PWD_FILE=$ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/.sysdba.passwd
	echo -n $SYSDBA_PWD > $SYSDBA_PWD_FILE
	chmod 600 $SYSDBA_PWD_FILE
	chown root:root $SYSDBA_PWD_FILE
}

# MAIN

# set SIGTERM handler
trap _term SIGTERM

# set SIGKILL handler
trap _kill SIGKILL

# check whether database already exists
if [ -d $ORACLE_BASE/oradata/$ORACLE_SID ]; then
	# prevent owner issues on mounted folders
	chown -R oracle:dba $ORACLE_BASE/oradata

	symLinkFiles;

	# make sure audit file destination exists
	if [ ! -d $ORACLE_BASE/admin/$ORACLE_SID/adump ]; then
		mkdir -p $ORACLE_BASE/admin/$ORACLE_SID/adump
		chown -R oracle:dba $ORACLE_BASE/admin/$ORACLE_SID/adump
	fi;
fi;

/etc/init.d/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR start | grep -qc "The Oracle Database is not configured. You must run '/etc/init.d/oracle-${ORACLE_SID,,}-$ORACLE_MAJOR configure' as the root user to configure the database."
if [ "$?" == "0" ]; then
	# check whether container has enough memory
	if [ `df -k /dev/shm | tail -n 1 | awk '{print $2}'` -lt 1048576 ]; then
		echo "Error: The container doesn't have enough memory allocated."
		echo "A database XE container needs at least 1 GB of shared memory (/dev/shm)."
		echo "You currently only have $((`df -k /dev/shm | tail -n 1 | awk '{print $2}'`/1024)) MB allocated to the container."
		exit 1;
	fi;

	# create database
	createDB;

	# install APEX
	if [ -f /tmp/apex_*.zip ]; then
		docker-apex-install.sh /tmp/apex_*.zip
	fi;

	export RUN_INITDB=true

fi;

if [ $RUN_INITDB ]; then
	echo "Starting import from '/docker-entrypoint-initdb.d':"

	for f in /docker-entrypoint-initdb.d/*
	do
		case "$f" in
			*.sh)
				echo "$0: running $f"
				$f
				;;
			*.sql)
				echo "$0: running $f"
					su -s /bin/bash oracle -c "sqlplus -S / as sysdba <<EOF
                      @$f
                      exit;
EOF"
				;;
			*.sql.gz)
				echo "$0: running $f"
				gunzip -c $f | su -s /bin/bash oracle -c "sqlplus -S / as sysdba"
				;;
			*.dmp)
				echo "$0: running $f"
				impdp $f
				;;
			*)
				echo "$0: ignoring $f"
				;;
		esac
	done
fi;

echo
echo "Oracle init process done. Database is ready to use."
echo

tail -f $ORACLE_BASE/diag/rdbms/*/*/trace/alert*.log &
CHILD_PID=$!
wait $CHILD_PID