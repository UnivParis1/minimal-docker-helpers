# check-updates and upgrade

## Debian images

### Context: Upstream security updates

* Debian has security updates, in a specific repository
* Debian publishes [PointReleases](https://wiki.debian.org/DebianReleases/PointReleases) every ~two months for `stable` and `oldstable`. It mostly puts security updates into the main repository.
* Docker Hub Debian images 
  * updates "at least once a month, but will also rebuild earlier if there is a major or minor Debian release or if there is a severe security issue that warrants doing so" ([ref](https://github.com/debuerreotype/docker-debian-artifacts?tab=readme-ov-file#update-frequency))
  * uses security repository

### Context: upgrades without Docker

When you use `apt update && apt upgrade` to do security updates, it is quite efficient and simple: 
* you get all security updates for installed packages
* only installed packages are upgraded

### Docker Images based on Debian images

When you use Dockerfile based on a debian image, things are more complex

* you must always `apt update` before `apt install`: otherwise it may fail to download package due to a package security update replacing a package with a new one
* if you pull a new Docker Hub Debian image, your image will be rebuilt completly, even if you do not use any of the updated packages
* if you want security updates more often than Docker Hub Debian images, you need to build with `--no-cache`
  * a solution to always have latest security updates:
```
# make the Docker cache dependent on security updates
ADD https://security.debian.org/debian-security/dists/trixie-security/InRelease /root/trixie-security-InRelease
```
* * But it will force a rebuild even if you do not use any of the updated packages

## check-updates

By default `/opt/dockers/do check-updates` only checks if there is a more recent image
* it does not use `docker pull` which would download the new image and change the local image names
* it calls a special script which does not change images, and does not download the image

### check-updates and .Dockerfile.cache-buster

If you add
```
COPY .Dockerfile.cache-buster /root/
RUN apt-get update && apt-get upgrade -y
# or RUN yum upgrade -y
# or RUN apk upgrade --no-cache"
```
in your Dockerfile, 

`/opt/dockers/do check-updates`
* will check if the distribution inside the image has security updates (using [this script](image-check-updates-using-package-manager.sh))
* will save a text file explaining the updates to be done in /opt/dockers/xxx/.Dockerfile.cache-buster

=> this will be used as a Docker build cache buster for `/opt/dockers/do upgrade`

## upgrade

`/opt/dockers/do upgrade` is doing
* `/opt/dockers/do pull`
* `/opt/dockers/do build`
* `/opt/dockers/do run --if-old`

If you called `/opt/dockers/do check-updates` first, it will trigger rebuild with latest distribution security updates for images using `.Dockerfile.cache-buster`.

## /opt/dockers/do pull

It mostly calls `docker pull`.

But `docker pull` removes previous image tag which is now known as `debian:<none>`.

To make things more readable `/opt/dockers/do pull` also calls `docker tag ... debian:xxx-prev` on previous image.
