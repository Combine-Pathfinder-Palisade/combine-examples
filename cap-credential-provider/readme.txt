Usage: java -jar cap-credentials-test-1.0.jar <password> <keystorePath>
Example: java -jar cap-credentials-test-1.0.jar "St0reP@ssw0rd!" "/home/ec2-user/npe_user_store.jks"

Relevant source code files:
combine-tutorial/src/main/java/com/sequoia/combine/test/tutorial/SSLRequestHelper.java
combine-tutorial/src/main/java/com/sequoia/combine/test/tutorial/CombineTutorialDriver.java
combine-tutorial/src/main/java/com/sequoia/combine/test/tutorial/CapCredentialsProvider.java

Project built with maven:
cd combine-tutorial
mvn clean package
