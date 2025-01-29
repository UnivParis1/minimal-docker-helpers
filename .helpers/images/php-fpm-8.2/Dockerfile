# Image PHP 8.2 basée sur Debian 12 incluant FPM et PHP CLI
# + les extensions PHP :
# - ctype date exif FFI fileinfo filter ftp gettext hash iconv libxml openssl pcre PDO Phar posix Reflection session shmop sockets sodium SPL standard sysvmsg sysvsem sysvshm tokenizer zlib
# - calendar cgi-fcgi Core random (par défaut aussi, mais ajouté à la liste PHP 7.4)
# - json opcache readline (paquets debian séparés mais obligatoires)
# - mbstring (paquets debian ajoutés manuellement car très utiles)
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get upgrade -y && \
  apt-get install -y php-fpm php-mbstring msmtp-mta
COPY etc /etc

ENTRYPOINT ["php-fpm8.2"]
