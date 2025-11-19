FROM debian:bookworm-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update
RUN apt-get install -y php-dev rpm2cpio cpio
RUN apt-get install -y wget

RUN wget https://download.oracle.com/otn_software/linux/instantclient/2390000/oracle-instantclient-basic-23.9.0.25.07-1.el9.x86_64.rpm
RUN wget https://download.oracle.com/otn_software/linux/instantclient/2390000/oracle-instantclient-devel-23.9.0.25.07-1.el9.x86_64.rpm
RUN for i in oracle-instantclient*.rpm; do rpm2cpio $i | cpio --extract --make-directories; done

RUN pecl install oci8-3.4.0
