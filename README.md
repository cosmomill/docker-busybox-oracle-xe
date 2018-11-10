BusyBox Oracle Database Express Edition (XE) 18c Docker image
=============================================================

This image is based on BusyBox GNU C library image ([busybox:glibc](https://hub.docker.com/r/_/busybox/)), which is only a 5MB image, and provides a docker image for Oracle Database Express Edition (XE) 18c.

Prerequisites
-------------

- If you want to build this image, you will need to download [Oracle Database Express Edition (XE) 18c for Linux x64](http://www.oracle.com/technetwork/database/database-technologies/express-edition/downloads/index.html).
- Oracle Database Express Edition (XE) 18c requires Docker 1.10.0 and above. *(Docker supports ```--shm-size``` since Docker 1.10.0)*
- Oracle Database Express Edition (XE) 18c uses shared memory for MEMORY_TARGET and needs at least 1 GB.

Usage Example
-------------

This image is intended to be a base image for your projects, so you may use it like this:

```Dockerfile
FROM cosmomill/busybox-oracle-xe

# Optional, auto import of sh, sql and dmp files at first startup
ADD my_schema.sql /docker-entrypoint-initdb.d/

# Optional, add required file for APEX installation
ADD apex_18.2.zip /tmp/

# Optional, set SYSDBA password
ENV SYSDBA_PWD my_secret

# Optional, set APEX admin password
ENV APEX_ADMIN_PWD my_secret

# Optional, set APEX listener password
ENV APEX_LISTENER_PWD my_secret

# Optional, set APEX REST public user password
ENV APEX_REST_PUBLIC_USER_PWD my_secret
```

```sh
$ docker build -t my_app . --build-arg ORACLE_RPM="oracle-database-xe-18c-1.0-1.x86_64.rpm"
```

```sh
$ docker run -d -P --shm-size=1g -v db_data:/opt/oracle/oradata -v apex_images:/opt/oracle/product/18c/dbhomeXE/apex/images -p 1521:1521 -p 5500:5500 my_app
```

Connect to database
-------------------

Auto generated passwords are stored in separate hidden files in ```/opt/oracle/oradata/dbconfig/XE``` with the naming system ```.username.passwd```.

Install APEX v18.2
------------------

If you want to install APEX v18.2, you will need to download [Oracle Application Express 18.2 - All languages](http://www.oracle.com/technetwork/developer-tools/apex/downloads/index.html) and add ```apex_18.2.zip``` to your image. *(See usage example above)*

The APEX installation will only happen if the entrypoint script finds the APEX install file in ```/tmp```.

**If you want to install APEX manually, follow this simple procedure.**

Execute ```docker-apex-install.sh``` on the container.

```sh
$ docker exec -it my_app docker-apex-install.sh /tmp/apex_18.2.zip
```

Setup a [Alpine Oracle REST Data Services](https://hub.docker.com/r/cosmomill/alpine-ords-apex/) container.
