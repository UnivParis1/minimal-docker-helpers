# Dockerisation légère

https://github.com/prigaux/notes/blob/main/migrate-debian-php-fpm-to-minimal-docker.md

## Mise à jour des images et conteneurs

```
/opt/dockers/do upgrade
```

## Détail des variables

### dans run.env

(modifiables par l'utilisateur applicatif)

  * `image` : par défaut `up1-$container_name` pour les conteneurs ayant un Dockerfile
  * `rw_vol` : (plusieurs lignes autorisées) répertoires montés en écriture (doivent être dans $base_dir)

### dans runOnce.env

(modifiables par l'utilisateur applicatif)

  * `image` : par défaut `up1-$container_name` pour les conteneurs ayant un runOnce.dockerfile
  * `subdir` : utilisé comme répertoire de travail. Par défaut `xxx` pour un $container_name `user--xxx` ou `xxx`
  * `cmd` : commande par défaut (si aucun paramètre)

### dans run.env et runOnce.env

  * `use_http_proxy_*` : 
    * `use_http_proxy_via=env` : configure les variables d'environnement http_proxy/https_proxy/no_proxy
    * `use_http_proxy_for=java` : configure http.proxyHost/http.proxyPort/https.proxyHost/https.proxyPort/http.nonProxyHosts via JDK_JAVA_OPTIONS
    * `use_http_proxy_for=maven` : configure http.proxyHost/http.proxyPort/https.proxyHost/https.proxyPort/http.nonProxyHosts via /usr/share/maven/conf/settings.xml

### dans run.sh et runOnce.sh

  * `$opts` : options passés à docker run
  * `$base_dir` : autorise `rw_vol` dans run.env
  * `$base_dir_template` : exemple `$base_dir_template='$user_home/www'`. Autorise `rw_vol` dans run.env
  * `$ro_vols` : répertoires montés en lecture seule :
    * `ro_vols=/webhome/foo` : monte /webhome/foo de l'hôte dans /webhome/foo dans le conteneur
    * `ro_vols=/webhome/foo:/usr/local` : monte /webhome/foo de l'hôte dans /usr/local dans le conteneur
  * `$rw_vols` : répertoires montés en lecture/écriture (avec ou sans `:` comme `$ro_vols`)
  * `$container_name` : utilisé pour calculer d'autres variables. Par défaut `xxx` pour un répertoire /opts/dockers/xxx
  * `$user` : utilisé pour calculer d'autres variables. Par défaut `xxx` pour un $container_name `xxx--subdir` ou `xxx`
  * `$logdir` : par défaut `/var/log/$container_name`
  * `$run_user` : utilisateur de l'hôte qui fait tourner le conteneur. Par défaut `$user`
  * `$run_group` : groupe de l'hôte qui fait tourner le conteneur. Par défaut `$user`
  * `$network_driver` : paramètre passé à docker run. Par défaut `host`
  * `$workdir` : paramètre passé à docker run

### Tomcat 

NB : il faut utiliser `. ./.helpers/tomcat/_run.sh` dans run.sh

dans run.sh :

  * `$port` : port http sur lequel tomcat doit écouter
  * `$webapps` : liste de répertoires à utiliser comme webapps
  * `$tomcat_logdir` : par défaut `$logdir/tomcat`
  * `$manager_password` : active tomcat /manager et configure le mot de passe de l'utilisateur `manager` avec droits "manager-script,manager-gui"

dans run.env :

  * `$maxPostSize` `$maxParameterCount` : modifier les paramètres par défaut de Tomcat
  * `$maxActiveSessionsGoal` : permet de limiter le nombre de sessions. Si le nombre de sessions dépasse ce nombre, les vieilles sessions sont supprimées. A utiliser avec précaution
  * `$remoteIpInternalProxies` : par défaut autorise uniquement les frontaux localhost
  * `$MaxHeapSize` : configure la RAM utilisée par Java (par défaut 25% de la RAM)


## Ajout d'une application

### Tomcat

Conventions :
  * /webhome/toto/webapps/ : où déployer
  * /var/log/toto/tomcat/ : contient les logs tomcat
  * /var/lib/sessions-toto/ : contient les sessions pendant le redémarrage
  * /var/log/docker/toto.log : contient les logs FPM + les "[error_log](https://github.com/prigaux/notes/blob/main/FPM-et-messages-de-logs-de-PHP.md)" (ajoutés via "syslog")

Ajout d'une application

  * créer un utilisateur local dans /webhome/toto , 
  * créer /opt/dockers/toto/runOnce.env . Exemple minimal :
```
image=maven:3-eclipse-temurin-17-alpine
subdir=src
cmd=mvn prepare-package war:exploded
```
  * compiler et déployer la webapp
    * pour maven, le plus performant est `sudo /opt/dockers/do runOnce toto` (pour les projets compliqués, utilisez plutôt https://stackoverflow.com/a/11134940/3005203 ) avec dans pom.xml :
      * `<build> <finalName>../../webapps/ROOT</finalName>`
      * `<plugin> <artifactId>maven-war-plugin</artifactId> <version>3.4.0</version> <configuration><outdatedCheckPath>/</outdatedCheckPath></configuration> </plugin>`
  * créer /opt/dockers/toto/run.sh . Exemple minimal :
```
#!/bin/sh
port=8480
webapps=/webhome/toto/webapps/*
. ./.helpers/tomcat/_run.sh
```
  * créer /opt/dockers/toto/run.env . Exemple minimal :
```
image=tomcat:9-jre21
```
  * exemple plus compliqué :

run.env
```
image=maven:3-eclipse-temurin-17-alpine
remoteIpInternalProxies="123[.]45[.]67[.]89"
```
run.sh
```
#!/bin/sh

port=8480
webapps=/webhome/toto/webapps/*

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
mvn --offline -Dmaven.resources.skip=true -Dmaven.test.skip=true -Dspring-boot.build-info.skip=true -Dmaven.antrun.skip=true spring-boot:run
```

Exemple complet :

  * run.env
```
image=maven:3-eclipse-temurin-17-alpine
```
  * run.sh
```
. .helpers/lib-run--set-vars.sh


dir=/webhome/toto/
ro_vols="$dir/.m2 $dir/src"

# do not use default ENTRYPOINT
opts="$opts --entrypoint="

_may_stop_and_rm
_docker_run mvn -f /webhome/toto/src/pom.xml --offline -Dmaven.resources.skip=true -Dmaven.test.skip=true -Dspring-boot.build-info.skip=true -Dmaven.antrun.skip=true spring-boot:run
```


## Ajout d'une version PHP-FPM

S'inspirer de .helpers/images/php-fpm-8.2
