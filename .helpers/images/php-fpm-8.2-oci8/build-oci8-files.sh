docker build -t oci8-files -f build-oci8.dockerfile .
docker run --rm oci8-files sh -c 'tar c /usr/lib/php/*/oci8.so /usr/*/oracle /etc/ld.so.conf.d/oracle-instantclient.conf' > oci8-files.tar
docker image rm oci8-files
