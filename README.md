# Dockerisation légère

https://github.com/prigaux/notes/blob/main/migrate-debian-php-fpm-to-minimal-docker.md

## Mise à jour des images et conteneurs

```
/opt/dockers/do upgrade --all
```

## Ajout d'une application

### Tomcat

Conventions :
  * /webhome/toto/webapps/ : où déployer
  * /var/log/toto/tomcat/ : contient les logs tomcat
  * /var/lib/sessions-toto/ : contient les sessions pendant le redémarrage

Ajout d'une application

  * créer un utilisateur local dans /webhome/toto , 
  * créer /opt/dockers/toto/runOnce.sh . Exemple minimal :
```
image=maven:3-eclipse-temurin-17-alpine
subdir=src
. .helpers/_runOnce.sh
```
  * compiler et déployer la webapp
    * pour maven, le plus performant est `sudo /opt/dockers/do runOnce toto mvn prepare-package war:exploded` (pour les projets compliqués, utilisez plutôt https://stackoverflow.com/a/11134940/3005203 ) avec dans pom.xml :
      * `<build> <finalName>../../webapps/ROOT</finalName>`
      * `<plugin> <artifactId>maven-war-plugin</artifactId> <version>3.4.0</version> <configuration><outdatedCheckPath>/</outdatedCheckPath></configuration> </plugin>`
  * créer /opt/dockers/toto/run.sh . Exemple minimal :
```
#!/bin/sh
port=8480
webapps=/webhome/toto/webapps/*
. ./.helpers/tomcat/_run.sh
```
  * exemple plus compliqué :
```
#!/bin/sh

port=8480
webapps=/webhome/toto/webapps/*

remoteIpInternalProxies="123[.]45[.]67[.]89"

ro_vols="/etc/krb5.conf /usr/local/etc/ssl"
rw_vols="/var/cache/toto"

. ./.helpers/tomcat/_run.sh
```
   * créer et lancer le conteneur
```
/opt/dockers/do run --logsf toto
```

### FPM

Conventions :
  * /webhome/toto/www/ : contient les fichiers PHP exécutable par FPM
  * /webhome/toto/.run/fpm.sock : Unix Socket à fournir à apache2/nginx
  * /var/lib/php/sessions-toto/ : contient les sessions

Ajout d'une application
  * créer un utilisateur local dans /webhome/toto et mettre les fichiers dans /webhome/toto/www
  * créer /opt/dockers/toto/Dockerfile, typiquement

```
FROM up1-php-fpm-8.2
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get install -y php-soap
COPY etc /etc/
```
   * si besoin, créer /opt/dockers/toto/etc/fpm-pool-opts.conf . Exemple :
```
php_value[memory_limit] = 256M
```
   * créer et lancer le conteneur
```
/opt/dockers/do build-run --logsf toto
```

### spring-boot:run

Avec les options suivantes, il est possible de démarrer un `mvn spring-boot:run` readonly après avoir fait `mvn compile` préalablement (avec `runOnce`) :

```
mvn -Dmaven.resources.skip=true -Dmaven.test.skip=true -Dspring-boot.build-info.skip=true -Dmaven.antrun.skip=true spring-boot:run
```

Exemple complet de `run.sh` :

```
image=maven:3-eclipse-temurin-17-alpine

. .helpers/lib-run.sh
_compute_default_vars
_handle_show_image_name "$@"


dir=/webhome/toto/
ro_vols="$dir/.m2 $dir/src"

# do not use default ENTRYPOINT
opts="$opts --entrypoint="

_may_stop_and_rm
_docker_run mvn -f /webhome/toto/src/pom.xml -Dmaven.resources.skip=true -Dmaven.test.skip=true -Dspring-boot.build-info.skip=true -Dmaven.antrun.skip=true spring-boot:run
```


## Ajout d'une version PHP-FPM

S'inspirer de .helpers/php-fpm/example-php-fpm-8.2
