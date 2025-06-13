# KeyCloak SAML POC

This project uses a dockerized Keycloak connected to a MySQL database in RDS to authenticate users in a dummy NodeJS app. 

*The architecture needs to be re-structured, but as of now we run Keycloak/docker on one EC2 and the node app on another. Keep this in mind as the documentation discusses installing things, copying files, and running things. Some is done on the Keycloak machine and some on the node machine.*

## Pre-Reqs
You need to install, at a minimum, the following:

1. Docker
2. MySQL
3. Node
4. NPM

## Set Up the DB
1) Set up a MySQL DB in RDS and save the connection string information as well as the admin username and password. You will need to use all of this when configuring the Keycloak Docker image.

*The RDS instance needs to be connected to the EC2 is running Keycloak/Docker.*

2) Connect to the DB instance with a SQL client and run:

```SQL
CREATE DATABASE keycloak;
```

You do not need to configure anything in the DB; Keycloak applies a custom schema when you pass DB parameters on start up. *But the DB name must be `keycloak`*

## Generate Certs
You will need certs for Keycloak and the Node app to run over HTTPS. Keycloak version 20.X.X requires HTTPS.

This can be achieved through the Combine admin console or the command line with a tool like `openssl`.

*Note that Keycloak seems to work better with a `.jks` file and password, while the node app uses the `key.pem` and `cert.pem`*

## Dockerize Keycloak
1) Open the `keycloak/dockerfile` and update the path on the last line (`{.JKS FILE PATH HERE}`)

2) Build an image from the `Keycloak/dockerfile`:

```bash
docker build -t {name}:{version} .
```

Example:
```bash
docker build -t keycloak-https:1.0 .
```
3) [Upload it to ECR](https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html).

Example:
```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 397173857460.dkr.ecr.us-east-1.amazonaws.com/keycloak2
docker images
docker tag a8fddcc46d02 397173857460.dkr.ecr.us-east-1.amazonaws.com/keycloak2
docker push 397173857460.dkr.ecr.us-east-1.amazonaws.com/keycloak2
```

4) Once you have built the Docker image, you can run the `docker_kc_run_command.sh` script

*Make sure you update the variables appropriately*

### Keycloak Configs
Once Keycloak is up and running, you need to set at least the following configs (you will need the node URLs/routes):

- create new realm
- create new client
    - use SAML
    - give it a client-id
    - update the following URLs:
        - Root URL
        - Home URL
        - Valid redirect URIs
    - "keys" tab
        - Client signature required > turn to "off"
- create browser flow requiring certificate authentication
- Make sure you navigate to Realm Settings > Endpoints > SAML 2.0 Identity Provider Metadata and copy the value of `<ds:X509Certificate>` for use in the Node app

## Configure and Run the Node app
1) The `idp-pub-key.pem` file contains a text string that you need to pull from Keycloak:

    - Navigate to the Keycloak dashboard
    - Select the appropriate realm
    - Select 'Realm Settings' from the bottom left
    - Select 'SAML 2.0 Identity Provider Metadata'
    - Copy the string in the `<ds:X509Certificate>` tag
    - Place the string in the `idp-pub-key.pem` file in the same directory as the node app

2) Place the `keycloakpoc.key.pem`,`keycloakpoc.cert.pem`, and `idp-pub-key.pem` in the same directory as the node app and update the variables and paths appropriately in the `app.js` code

3) Update the following blocks:

```javascript
const samlConfig = {
    issuer: "poc-application", //name of client in Keycloak
    entityId: "Saml-SSO-App",
    callbackUrl: "https://app.keycloak.sequoiacombine.io:3000/login/callback", //redirect URL in Keycloak
    signOut: "https://app.keycloak.sequoiacombine.io:3000/signout/callback",
    entryPoint: "https://poc.keycloak.sequoiacombine.io/realms/combine/protocol/saml", //Keycloak SAML endpoint
};
```

```javascript
const samlStrategy = new saml.Strategy({
    ...
    ...
    privateCert: fs.readFileSync('keycloakpoc.key.pem', 'utf8'),
    ...
    ...
});
```

```javascript
//Run the https server
const server = https.createServer({
    ...
    ...
    'passphrase': {INSERT_KEYFILE_PASSWORD_HERE}
    ...
    ...
});
```

4) Once all variables, URLs, cert file paths, and passwords are updated, run the install command to download necessary packages:

```bash
npm install
```

5) Run the following command to start the web app:

```bash
node app.js
```

If you get an error because of faulty libraries, you may want to downgrade to version 16.X.X:

```bash
nvm install 16
nvm use 16
```

You should see that the app is listening on port 3000 and is accessible via `https://{IP}:3000` or the DNS name you have configured via route53.