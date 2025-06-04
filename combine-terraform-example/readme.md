This is a simple terraform configuration that details how to interact with Combine's implementation of the CAP API and endpoint emulation, and provisions a simple SQS stack in the account.

The 'meat' of the configuration is in the provider block. Note that:
- the region is set to the high side region your account is emulating.
- the custom ca bundle argument is set to Combine's ca chain, which you received in your credential bundle.
- the access and secret key are set to values you received from the CAP API when you initiated a call to the `/credentials` endpoint.
  - information about how to make this call must be obtained from a Combine team member.

The terraform also provisions a simple SQS queue. In this resource, note that the ARNs are set to the emulated partition and the emulated region.

Please email our team at <a href="mailto:service-request@sequoiainc.com>service-request@sequoiainc.com</a">, or reach out to us in Slack for any questions!