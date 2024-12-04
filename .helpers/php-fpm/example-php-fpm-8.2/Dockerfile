# Debian 12
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get upgrade -y && \
  apt-get install -y php-fpm
COPY etc /etc

ENTRYPOINT ["php-fpm8.2"]
