package com.sequoia.combine.test.tutorial;

import java.util.HashMap;
import java.util.Map;

public class CombineTutorialDriver {

  public static void main(String[] args) {
    Map<String, String> argMap = parseArguments(args);

    // Default values for optional arguments
    String agency = argMap.getOrDefault("agency", "Combine");
    String mission = argMap.getOrDefault("mission", "CCustomer");
    String endpoint = argMap.get("endpoint");
    String role = argMap.getOrDefault("role", "WLDEVELOPER-" + endpoint);

    // Required arguments
    if (!argMap.containsKey("password") || !argMap.containsKey("keystorePath") || endpoint == null) {
      printUsage();
      System.exit(1);
    }

    if (!endpoint.equals("C2S") && !endpoint.equals("SC2S")) {
      System.err.println("ERROR: Invalid endpoint argument. Valid options are 'C2S' and 'SC2S'.");
      System.exit(1);
    }

    if (!role.endsWith("-" + endpoint)) {
      System.err.println("ERROR: Role suffix does not match the provided endpoint.");
      System.exit(1);
    }

    String password = argMap.get("password");
    String keystorePath = argMap.get("keystorePath");
    String targetUrl = determineTargetUrl(endpoint);

    // Display chosen values
    System.out.println("----------------------");
    System.out.println("Using settings:");
    System.out.println("  Agency:       " + agency);
    System.out.println("  Mission:      " + mission);
    System.out.println("  Role:         " + role);
    System.out.println("  Endpoint:     " + endpoint);
    System.out.println("  Target URL:   " + targetUrl);
    System.out.println("  KeystorePath: " + keystorePath);
    System.out.println("----------------------");

    // Initialize credentials provider
    CapCredentialsProvider provider = new CapCredentialsProvider(agency, mission, role, password, keystorePath, targetUrl);
    provider.resolveCredentials();
  }

  private static String determineTargetUrl(String endpoint) {
    switch (endpoint) {
      case "SC2S":
        return "https://geoaxis.nga.smil.mil/cap/gxCAP/getTemporaryCredentials";
      case "C2S":
        // Retrieve the following URL from a combine team member.
        return "https://www.google.com";
      default:
        throw new IllegalArgumentException("ERROR: Unknown endpoint.");
    }
  }

  /**
   * Parses command-line arguments into a key-value map.
   * Supports named arguments in the format --key=value
   */
  private static Map<String, String> parseArguments(String[] args) {
    Map<String, String> argMap = new HashMap<>();
    for (String arg : args) {
      if (arg.startsWith("--")) {
        String[] keyValue = arg.substring(2).split("=", 2);
        if (keyValue.length == 2) {
          argMap.put(keyValue[0], keyValue[1]);
        }
      }
    }
    return argMap;
  }

  /*
   * Prints usage instructions with default values.
   */
  private static void printUsage() {
    System.out.println("Usage: java -jar cap-credentials-test-1.0.jar --password=<password> --keystorePath=<path> --endpoint=<C2S|SC2S> [OPTIONS]");
    
    System.out.println("\nRequired Arguments:");
    System.out.println("  --password=<password>        (No default, must be provided)");
    System.out.println("  --keystorePath=<path>        (No default, must be provided)");
    System.out.println("  --endpoint=<C2S|SC2S>        (Must be provided, determines target URL)");

    System.out.println("\nOptional Arguments (Defaults shown):");
    System.out.println("  --agency=<agency>            (Default: Combine)");
    System.out.println("  --mission=<mission>          (Default: CCustomer)");
    System.out.println("  --role=<role>                (Default: WLDEVELOPER-C2S)");

    System.out.println("\nExamples:");
    System.out.println("  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --endpoint=C2S");
    System.out.println("  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=NewAgency --mission=NewMission --role=NewRole --endpoint=SC2S");

    System.out.println("\nSC2S Role Example:");
    System.out.println("  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=Combine --mission=CCustomer --role=WLDEVELOPER-SC2S --endpoint=SC2S");

    System.out.println("\nC2S Role Example:");
    System.out.println("  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=Combine --mission=CCustomer --role=WLDEVELOPER-C2S --endpoint=C2S");
  }
}
