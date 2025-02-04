Usage: java -jar cap-credentials-test-1.0.jar --password=<password> --keystorePath=<path> --endpoint=<C2S|SC2S> [OPTIONS]
Example: java -jar cap-credentials-test-1.0.jar --password="St0reP@ssw0rd!" --keystorePath="/home/ec2-user/npe_user_store.jks" --endpoint=C2S

Required Arguments:
  --password=<password>        (No default, must be provided)
  --keystorePath=<path>        (No default, must be provided)
  --endpoint=<C2S|SC2S>        (Must be provided, determines target URL and default role value)

Optional Arguments (Defaults shown):
  --agency=<agency>            (Default: Combine)
  --mission=<mission>          (Default: CCustomer)
  --role=<role>                (Default: WLDEVELOPER-[endpoint])

Examples:
  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --endpoint=C2S
  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=NewAgency --mission=NewMission --role=NewRole --endpoint=SC2S

SC2S Role Examples:
  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=Combine --mission=CCustomer --role=WLDEVELOPER-SC2S --endpoint=SC2S
  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=Combine --mission=CCustomer --role=KEYMANAGER-SC2S --endpoint=SC2S
  
C2S Role Example:
  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=Combine --mission=CCustomer --role=WLDEVELOPER-C2S --endpoint=C2S
  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=Combine --mission=CCustomer --role=KEYMANAGER-C2S --endpoint=C2S
