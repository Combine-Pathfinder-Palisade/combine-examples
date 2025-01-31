package com.sequoia.combine.test.tutorial;

public class CombineTutorialDriver {

  public static void main(String[] args) {
    if (args.length < 2) {
      System.out.println("Usage: java -jar cap-credentials-test-1.0.jar <password> <keystorePath>");
      System.exit(1);
    }

    String password = args[0];
    String keystorePath = args[1];

    CapCredentialsProvider provider = new CapCredentialsProvider("Combine", "CCustomer", "WLDEVELOPER-C2S", password, keystorePath);
    provider.resolveCredentials();
  }
}
