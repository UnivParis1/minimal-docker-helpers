# Image PHP 7.4 basée sur Debian 11 incluant FPM et PHP CLI
# + les extensions PHP :
# - ctype date exif FFI fileinfo filter ftp gettext hash iconv libxml openssl pcre PDO Phar posix Reflection session shmop sockets sodium SPL standard sysvmsg sysvsem sysvshm tokenizer zlib
# - json opcache readline (paquets debian séparés mais obligatoires)
# - mbstring (paquets debian ajoutés manuellement car très utiles)
FROM debian:bullseye-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get upgrade -y && \
  apt-get install -y php-fpm php-mbstring msmtp-mta
COPY etc /etc

ENTRYPOINT ["php-fpm7.4"]
