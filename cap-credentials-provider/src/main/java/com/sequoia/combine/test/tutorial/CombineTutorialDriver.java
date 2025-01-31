package com.sequoia.combine.test.tutorial;

import java.util.HashMap;
import java.util.Map;

public class CombineTutorialDriver {

  public static void main(String[] args) {
    Map<String, String> argMap = parseArguments(args);

    // Default values for optional arguments
    String agency = argMap.getOrDefault("agency", "Combine");
    String mission = argMap.getOrDefault("mission", "CCustomer");
    String role = argMap.getOrDefault("role", "WLDEVELOPER-C2S");

    // Required arguments
    if (!argMap.containsKey("password") || !argMap.containsKey("keystorePath")) {
      printUsage();
      System.exit(1);
    }

    String password = argMap.get("password");
    String keystorePath = argMap.get("keystorePath");

    // Display chosen values
    System.out.println("Using settings:");
    System.out.println("  Agency:       " + agency);
    System.out.println("  Mission:      " + mission);
    System.out.println("  Role:         " + role);
    System.out.println("  KeystorePath: " + keystorePath);

    // Initialize credentials provider
    CapCredentialsProvider provider = new CapCredentialsProvider(agency, mission, role, password, keystorePath);
    provider.resolveCredentials();
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

  /**
   * Prints usage instructions with default values.
   */
  private static void printUsage() {
    System.out.println("Usage: java -jar cap-credentials-test-1.0.jar --password=<password> --keystorePath=<path> [OPTIONS]");
    System.out.println("\nRequired Arguments:");
    System.out.println("  --password=<password>        (No default, must be provided)");
    System.out.println("  --keystorePath=<path>        (No default, must be provided)");

    System.out.println("\nOptional Arguments (Defaults shown):");
    System.out.println("  --agency=<agency>            (Default: Combine)");
    System.out.println("  --mission=<mission>          (Default: CCustomer)");
    System.out.println("  --role=<role>                (Default: WLDEVELOPER-C2S)");

    System.out.println("\nExample:");
    System.out.println("  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore");
    System.out.println("  java -jar cap-credentials-test-1.0.jar --password=mySecret --keystorePath=/path/to/keystore --agency=NewAgency --mission=NewMission --role=NewRole");
  }
}
