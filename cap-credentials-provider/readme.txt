Usage: java -jar cap-credentials-test-1.0.jar --password=<password> --keystorePath=<path> [OPTIONS]
Example: java -jar cap-credentials-test-1.0.jar --password="St0reP@ssw0rd!" --keystorePath="/home/ec2-user/npe_user_store.jks"

Required Arguments:
  --password=<password>        (No default, must be provided)
  --keystorePath=<path>        (No default, must be provided)

Optional Arguments (Defaults shown):
  --agency=<agency>            (Default: Combine)
  --mission=<mission>          (Default: CCustomer)
  --role=<role>                (Default: WLDEVELOPER-C2S)

Example:
  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore
  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=NewAgency --mission=NewMission --role=NewRole

Relevant source code files:
src/main/java/com/sequoia/combine/test/tutorial/SSLRequestHelper.java
src/main/java/com/sequoia/combine/test/tutorial/CombineTutorialDriver.java
src/main/java/com/sequoia/combine/test/tutorial/CapCredentialsProvider.java
