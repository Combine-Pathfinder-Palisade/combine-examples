# EMR Bootstrapping Example

## Overview
The `bootstrap-emr.sh` script configures an Amazon EMR cluster node to trust the Combine CA chain and to direct AWS CLI traffic toward the high-side endpoints. It performs four actions:

1. Downloads the CA bundle from the shard-specific DevOps bucket and places it in `/etc/pki/ca-trust/source/anchors`.
2. Refreshes the host trust store so the new CA takes effect system-wide.
3. Writes `/etc/profile.d/combine-env.sh` so future shell sessions export `AWS_REGION`, `AWS_DEFAULT_REGION`, and `AWS_CA_BUNDLE` with the ISO region and new CA path.
4. Configures the root user's `~/.aws/config` to default to the ISO region and CA bundle.

## Prerequisites
- **IAM permissions:** The instance profile attached to the EMR cluster must allow `s3:GetObject` for the CA object in your bucket.
- **Region variables:** Change the host and emulated regions in the script if needed. Default regions are:
  ```bash
  HOST_REGION="us-east-1"
  EMULATED_REGION="us-iso-east-1"
  ...
  ```



## Using the script as an EMR bootstrap action
1. Upload `bootstrap-emr.sh` to an S3 location reachable by the EMR cluster.
2. When creating the EMR cluster, add a bootstrap action that runs the script and passes the shard name and account ID arguments.
- *CLI Example:*
   ```bash
   aws emr create-cluster \
     --name combine-iso-test \
     ...
      --bootstrap-actions '[{"Args":["shardName","accountID"],"Name":"Combine BA","Path":"s3://my-bucket/bootstrap-emr.sh"}]'
   ```
- *Console Example:*

  ![alt text](image.png)
3. The bootstrap action runs on every core/task node as it joins the cluster, ensuring consistent trust configuration throughout the fleet.
