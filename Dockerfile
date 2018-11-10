FROM busybox:glibc

MAINTAINER Rene Kanzler, me at renekanzler dot com

# grab apt-off to install debian binary packages
RUN mkdir -p /usr/local/bin \
	&& wget --no-check-certificate https://raw.githubusercontent.com/cosmomill/apt-off/master/apt-off -O /usr/local/bin/apt-off \
	&& chmod 755 /usr/local/bin/apt-off \
	&& mkdir -p /var/lib/apt/lists \
	\
# create sources.list
	&& mkdir -p /etc/apt \
	&& echo "deb http://deb.debian.org/debian/ stable main" > /etc/apt/sources.list \
	\
# create dpkg status file
	&& mkdir -p /var/lib/dpkg/info \
	&& touch /var/lib/dpkg/status

# add bash to make sure our scripts will run smoothly
RUN /usr/local/bin/apt-off -i bash-static \
	\
# install Oracle XE prerequisites
	libc6 \
	libgcc1 \
	libaio1 \
	libstdc++6 \
	libc-bin

# cleanup
RUN /usr/local/bin/apt-off -p

RUN mkdir /docker-entrypoint-initdb.d

# add symlink to bash
RUN ln -s /bin/bash-static /bin/bash \
	\
# add symlink to libaio, id, sysctl, ar
	&& ln -s /lib/x86_64-linux-gnu/libaio.so.1 /lib/libaio.so.1 \
	&& ln -s /usr/lib/x86_64-linux-gnu/libstdc++.so.6 /usr/lib/libstdc++.so.6 \
	&& mkdir -p /usr/bin \
	&& ln -s /bin/id /usr/bin/id \
	&& ln -s /bin/ar /usr/bin/ar \
	&& ln -s /bin/sysctl /sbin/sysctl \
	\
# create .oracle directory
	&& mkdir -p /var/tmp/.oracle \
	&& chmod 01777 /var/tmp/.oracle

ONBUILD ARG ORACLE_RPM

ENV ORACLE_MAJOR 18c
ENV ORACLE_VERSION 18c-1.0-1
ENV ORACLE_BASE /opt/oracle
ENV ORACLE_HOME /opt/oracle/product/$ORACLE_MAJOR/dbhomeXE
ENV ORACLE_SID XE
ENV PATH $PATH:$ORACLE_HOME/bin

# install Oracle XE
ONBUILD ADD $ORACLE_RPM /tmp/
ONBUILD RUN rpm -i /tmp/$ORACLE_RPM \
	&& rm -f /tmp/$ORACLE_RPM

# add Oracle user and group
ONBUILD RUN addgroup dba \
	&& addgroup oinstall \
	&& adduser -D -g oinstall -G dba -h $ORACLE_BASE -s /bin/false oracle \
	\
# create mountable directorys
	&& mkdir -p $ORACLE_BASE/oradata \
	&& mkdir -p $ORACLE_HOME/apex/images \
	\
# set permissions
	&& chown -R oracle:dba $ORACLE_BASE \
	\
# set sticky bit to oracle executable
	&& chmod 6751 $ORACLE_HOME/bin/oracle \
	\
# fix command arguments in init script
	&& sed -i "s|--no-messages|-s|" /etc/init.d/oracle-xe-$ORACLE_MAJOR \
	&& sed -i "s|--direct||" /etc/init.d/oracle-xe-$ORACLE_MAJOR \
	&& sed -i "s|netstat -n --tcp --listen|netstat -ntl|" /etc/init.d/oracle-xe-$ORACLE_MAJOR \
	&& sed -i "s|-J-Doracle.assistants.dbca.validate.DBCredentials=false|-J-Doracle.assistants.dbca.validate.DBCredentials=false -J-Doracle.assistants.dbca.validate.ConfigurationParams=false|" /etc/init.d/oracle-xe-$ORACLE_MAJOR

# add alias conndba
RUN echo "alias conndba='su -s \"/bin/bash\" oracle -c \"sqlplus / as sysdba\"'" >> /etc/bash.bashrc

# define mountable directories
ONBUILD VOLUME $ORACLE_BASE/oradata $ORACLE_HOME/apex/images

COPY docker-entrypoint.sh /usr/local/bin/
COPY docker-apex-install.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh \
	&& chmod 755 /usr/local/bin/docker-apex-install.sh

ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 1521 5500
CMD [""]