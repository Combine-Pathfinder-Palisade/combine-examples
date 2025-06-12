# Instructions For Running bootstrap-ssm.sh #

1. Make sure that bootstrap-ssm.sh and your custom CA are located inside of your endpoint. You can either directly move them to a 
   temporary directory inside of your endpoint environment, or secure copy them using scp from your local machine to the remote server.

2. Open the script and update the following fields to your desired settings
   CUSTOM_CA_SOURCE_PATH=" " <-- change this to the location of your custom certificate
   CUSTOM_CA_FILE=" " <-- change this to your custom certificate
   SSM_ENDPOINT=" " <-- change this to your endpoint server url (ex. https://ssm.us-iso-east-1.c2s.gov)
   REGION=" " <-- change this to your region (ex. us-iso-east-1)

3. chmod the script to ensure that it is executable

4. Execute the script. Make sure to use sudo and bash

5. Check to ensure that the script executed successfully. Run these commands:
   sudo systemctl status amazon-ssm-agent --no-pager
   - If successful, you should see that the server is active, loaded, and the logs should indicate a healthy connection to the backend

   sudo tail -f /var/log/amazon/ssm/amazon-ssm-agent.log
   - some key things you should see are "using endpoint", "successful connection to Systems Manager", "Successfully registered the instance", 
     "and starting message polling". You DON'T want to see anything like "TLS handshake failed", "unable to connect to endpoint", and any other invalid or failed message