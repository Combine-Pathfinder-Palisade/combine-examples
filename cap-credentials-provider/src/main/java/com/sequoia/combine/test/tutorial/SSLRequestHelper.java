package com.sequoia.combine.test.tutorial;

import java.io.File;

import javax.net.ssl.SSLContext;

import org.apache.http.HttpResponse;
import org.apache.http.client.HttpClient;
import org.apache.http.client.methods.HttpGet;
import org.apache.http.conn.ssl.SSLConnectionSocketFactory;
import org.apache.http.impl.client.HttpClients;
import org.apache.http.ssl.SSLContextBuilder;
import org.apache.http.util.EntityUtils;

public final class SSLRequestHelper {
  private final HttpClient client;

  public SSLRequestHelper(String password, String filePath) {
    
    try {
      SSLContext sslContext = SSLContextBuilder.create().loadKeyMaterial(
          new File(filePath), // TODO: Enter your file name
          password.toCharArray(),     // Store password
          password.toCharArray()      // Key password
        ).loadTrustMaterial(
          new File(filePath) // TODO: Enter your file name
      ).build();

      SSLConnectionSocketFactory connectionFactory = new SSLConnectionSocketFactory(sslContext);

      client = HttpClients.custom().setSSLSocketFactory(connectionFactory).build();
    } catch (Exception e) {
      throw new RuntimeException("ERROR: Could not initialize request helper!", e);
    }
  }

  public String get(String url) {
    try {
      System.out.println("URL is: " + url);
      HttpResponse response = client.execute(new HttpGet(url));

      return EntityUtils.toString(response.getEntity());
    } catch (Exception e) {
      throw new RuntimeException("ERROR: GET Request Failed", e);
    }
  }
}
