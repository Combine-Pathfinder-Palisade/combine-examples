package com.sequoia.combine.test.tutorial;

import java.util.Date;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import software.amazon.awssdk.auth.credentials.AwsCredentials;
import software.amazon.awssdk.auth.credentials.AwsCredentialsProvider;
import software.amazon.awssdk.auth.credentials.AwsSessionCredentials;

public final class CapCredentialsProvider implements AwsCredentialsProvider {

  protected final String agency;
  protected final String mission;
  protected final String role;
  protected final String password;
  protected final String filePath;
  protected final String targetUrl;

  private Date refreshed = null;

  private AwsCredentials credentials = null;

  public CapCredentialsProvider(String agency, String mission, String role, String password, String filePath, String targetUrl) {
    this.agency = agency;
    this.mission = mission;
    this.role = role;
    this.password = password;
    this.filePath = filePath;
    this.targetUrl = targetUrl;
  }

    public AwsCredentials resolveCredentials() {
      if (refreshed == null || new Date().getTime() - refreshed.getTime() > 1000*60*45) { // Building in a 15 minute buffer.
        try {
          refresh();
        } catch (Exception e) {
          // TODO: Catching and suppressing this exception means that if CAP goes down you will keep using your cached token until it expires.
          e.printStackTrace();
        }
      }
      return credentials;
    }

  private void refresh() {
    SSLRequestHelper helper = new SSLRequestHelper(password, filePath); // TODO: Truststore/Keystore password!

    String requestUrl;
    
    // Dynamically modify the query parameters based on the role suffix
    if (role.endsWith("-SC2S")) {
        requestUrl = targetUrl + "?agency=" + agency + "&accountName=" + mission + "&roleName=" + role;
    } else if (role.endsWith("-C2S")) {
        requestUrl = targetUrl + "?agency=" + agency + "&mission=" + mission + "&role=" + role;
    } else {
        throw new IllegalArgumentException("ERROR: Unknown role format. Expected suffix '-C2S' or '-SC2S'. Role provided: " + role);
    }

    String credentialsString = helper.get(requestUrl);
  
    System.out.println("----------------------");
    System.out.println(credentialsString);
    System.out.println("----------------------");

    JsonObject credentialsJson = JsonParser.parseString(credentialsString).getAsJsonObject();

    credentialsJson = credentialsJson.get("Credentials").getAsJsonObject();

    credentials = AwsSessionCredentials.create(
        credentialsJson.get("AccessKeyId").getAsString(),
        credentialsJson.get("SecretAccessKey").getAsString(),
        credentialsJson.get("SessionToken").getAsString()
    );

     
    refreshed = new Date();
  }
}