#!/bin/bash

CONTAINER_NAME=  # Give the Docker container a name
PATH_TO_JKS=  # Should be `/opt/keycloak/{file_name}.jks` according to the dockerfile
JKS_PASSWORD=
PATH_TO_TRUST_STORE=  # if using the .jks, path and password will be the same for JKS and TRUST_STORE
TRUST_STORE_PASSWORD=
CLIENT_AUTH='request' # none, request, or required
DOCKER_IMAGE_NAME=  # Make sure this is the name of the image you created from the dockerfile
DB_TYPE='mysql' # mysql, postgres, etc.
DB_HOST_URL=  # Available in RDS
DB_USERNAME=  # Set in RDS
DB_PASSWORD=  # Set in RDS

docker run \
--name "$CONTAINER_NAME" \
-e KC_HTTPS_KEY_STORE_FILE="$PATH_TO_JKS" \
-e KC_HTTPS_KEY_STORE_PASSWORD="$JKS_PASSWORD" \
-e KC_HTTPS_TRUST_STORE_FILE="$PATH_TO_TRUST_STORE" \
-e KC_HTTPS_TRUST_STORE_PASSWORD="$TRUST_STORE_PASSWORD" \
-e KC_HTTPS_CLIENT_AUTH="$CLIENT_AUTH" \
-p 443:443 \
"$DOCKER_IMAGE_NAME" start --log=console,file --log-level=DEBUG --db "$DB_TYPE" --db-url-host "$DB_HOST_URL" --db-username "$DB_USERNAME" --db-password "$DB_PASSWORD"