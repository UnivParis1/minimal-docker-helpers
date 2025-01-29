FROM up1-php-fpm-7.4
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get install -y libaio1

ADD oci8-files.tar /
RUN ldconfig

RUN echo 'extension=oci8.so' > /etc/php/7.4/mods-available/oci8.ini
RUN phpenmod oci8
