FROM debian:bullseye-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update
RUN apt-get install -y php-dev rpm2cpio cpio
RUN apt-get install -y wget

RUN wget https://download.oracle.com/otn_software/linux/instantclient/19600/oracle-instantclient19.6-basic-19.6.0.0.0-1.x86_64.rpm
RUN wget https://download.oracle.com/otn_software/linux/instantclient/19600/oracle-instantclient19.6-devel-19.6.0.0.0-1.x86_64.rpm
RUN for i in oracle-instantclient*.rpm; do rpm2cpio $i | cpio --extract --make-directories; done

RUN pecl install oci8-2.2.0