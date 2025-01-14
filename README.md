# Dockerisation légère

https://github.com/prigaux/notes/blob/main/migrate-debian-php-fpm-to-minimal-docker.md

## Mise à jour des images et conteneurs

```
/opt/dockers/do upgrade --all
```

## Détail des variables

### en général dans run.sh et runOnce.sh

  * `$opts` : options passés à docker run
  * `$ro_vols` : volumes montés en lecture seule :
    * `ro_vols=/webhome/foo` : monte /webhome/foo de l'hôte dans /webhome/foo dans le conteneur
    * `ro_vols=/webhome/foo:/usr/local` : monte /webhome/foo de l'hôte dans /usr/local dans le conteneur
  * `$rw_vols` : volumes montés en lecture/écriture (avec ou sans `:` comme `$ro_vols`)
  * `$container_name` : utilisé pour calculer d'autres variables. Par défaut `xxx` pour un répertoire /opts/dockers/xxx
  * `$image` : par défaut `up1-$container_name` pour les conteneurs ayant un Dockerfile
  * `$user` : utilisé pour calculer d'autres variables. Par défaut `xxx` pour un $container_name `xxx--subdir` ou `xxx`
  * `$subdir` : utilisé pour calculer d'autres variables. Par défaut `xxx` pour un $container_name `user--xxx` ou `xxx`
  * `$logdir` : par défaut `/var/log/$container_name`
  * `$run_user` : utilisateur de l'hôte qui fait tourner le conteneur. Par défaut `$user`
  * `$run_group` : groupe de l'hôte qui fait tourner le conteneur. Par défaut `$user`
  * `$network_driver` : passé à docker run. Par défaut `host`
  * `$workdir` : passé à docker run
  * `$use_http_proxy` : 
    * `use_http_proxy=java` : configure http.proxyHost/http.proxyPort/https.proxyHost/https.proxyPort/http.nonProxyHosts via JDK_JAVA_OPTIONS
    * `use_http_proxy=maven` : configure http.proxyHost/http.proxyPort/https.proxyHost/https.proxyPort/http.nonProxyHosts via /usr/share/maven/conf/settings.xml

### Tomcat 

NB : il faut utiliser `. ./.helpers/tomcat/_run.sh` dans run.sh

  * `$port` : port http sur lequel tomcat doit écouter
  * `$webapps` : liste de répertoires à utiliser comme webapps
  * `$maxPostSize` `$maxParameterCount` : modifier les paramètres par défaut de Tomcat
  * `$maxActiveSessionsGoal` : permet de limiter le nombre de sessions. Si le nombre de sessions dépasse ce nombre, les vieilles sessions sont supprimées. A utiliser avec précaution
  * `$remoteIpInternalProxies` : par défaut autorise uniquement les frontaux localhost
  * `$tomcat_logdir` : par défaut `$logdir/tomcat`
  * `$manager_password` : active tomcat /manager et configure le mot de passe de l'utilisateur `manager` avec droits "manager-script,manager-gui"


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
```
   * si besoin, créer /opt/dockers/toto/etc/fpm-pool-opts.conf . Exemple :
```
php_value[memory_limit] = 256M
```
et ajouter
```
COPY etc /etc/
```
dans /opt/dockers/toto/Dockerfile
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
