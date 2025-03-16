# Image PHP 7.4 basée sur Debian 11 incluant FPM et PHP CLI
# + les extensions PHP :
# - ctype date exif FFI fileinfo filter ftp gettext hash iconv libxml openssl pcre PDO Phar posix Reflection session shmop sockets sodium SPL standard sysvmsg sysvsem sysvshm tokenizer zlib
# - json opcache readline (paquets debian séparés mais obligatoires)
# - mbstring (paquets debian ajoutés manuellement car très utiles)
FROM debian:bullseye-slim

# faire dépendre le docker cache des mises à jour de sécurité est mis à jour
ADD https://security.debian.org/debian-security/dists/bullseye-security/InRelease /root/bullseye-security-InRelease

ARG DEBIAN_FRONTEND=noninteractive
RUN echo 'APT::Install-Recommends "false";' > /etc/apt/apt.conf.d/No-Recommends
RUN apt-get update && apt-get upgrade -y && \
  apt-get install -y php-fpm php-mbstring msmtp-mta locales && \
  localedef -i fr_FR -c -f UTF-8 -A /usr/share/locale/locale.alias fr_FR.UTF-8
# NB : on génère la locale française (comme expliqué ici https://hub.docker.com/_/debian ). On n'a pas trouvé d'applis en dépendant mais c'est plus sûr...
ENV LANG fr_FR.UTF-8
COPY etc /etc

ENTRYPOINT ["php-fpm7.4"]
