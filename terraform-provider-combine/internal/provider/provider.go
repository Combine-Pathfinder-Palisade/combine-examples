package provider

import (
	"context"
	"fmt"
	"os"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/combine-pathfinder-palisade/terraform-provider-combine/internal/client"
	"github.com/hashicorp/terraform-plugin-framework/datasource"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/provider"
	"github.com/hashicorp/terraform-plugin-framework/provider/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var _ provider.Provider = (*combineProvider)(nil)

type combineProvider struct {
	version string
}

type combineProviderModel struct {
	Endpoint       types.String `tfsdk:"endpoint"`
	ClientCertPath types.String `tfsdk:"client_cert_path"`
	ClientKeyPath  types.String `tfsdk:"client_key_path"`
	CACertPath     types.String `tfsdk:"ca_cert_path"`

	EndpointSecretID   types.String `tfsdk:"endpoint_secret_id"`
	ClientCertSecretID types.String `tfsdk:"client_cert_secret_id"`
	ClientKeySecretID  types.String `tfsdk:"client_key_secret_id"`
	CACertSecretID     types.String `tfsdk:"ca_cert_secret_id"`
	AWSRegion          types.String `tfsdk:"aws_region"`
	AWSAccessKeyID     types.String `tfsdk:"aws_access_key_id"`
	AWSSecretAccessKey types.String `tfsdk:"aws_secret_access_key"`
}

func New(version string) func() provider.Provider {
	return func() provider.Provider {
		return &combineProvider{version: version}
	}
}

func (p *combineProvider) Metadata(_ context.Context, _ provider.MetadataRequest, resp *provider.MetadataResponse) {
	resp.TypeName = "combine"
	resp.Version = p.version
}

func (p *combineProvider) Schema(_ context.Context, _ provider.SchemaRequest, resp *provider.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Combine TAP provider. Manages users, groups, and AWS roles via the TAP API over mTLS.",
		Attributes: map[string]schema.Attribute{
			"endpoint": schema.StringAttribute{
				Optional:    true,
				Description: "TAP base URL (e.g. https://tap.example.com/tap). Falls back to COMBINE_TAP_ENDPOINT.",
			},
			"client_cert_path": schema.StringAttribute{
				Optional:    true,
				Description: "Path to PEM client certificate. Falls back to COMBINE_TAP_CLIENT_CERT.",
			},
			"client_key_path": schema.StringAttribute{
				Optional:    true,
				Description: "Path to PEM client private key. Falls back to COMBINE_TAP_CLIENT_KEY.",
				Sensitive:   true,
			},
			"ca_cert_path": schema.StringAttribute{
				Optional:    true,
				Description: "Path to the CA cert that signs the TAP server certificate. Falls back to COMBINE_TAP_CA_CERT.",
			},

			"endpoint_secret_id": schema.StringAttribute{
				Optional:    true,
				Description: "AWS Secrets Manager secret ID whose plaintext is the TAP endpoint URL. Mutually exclusive with `endpoint`.",
			},
			"client_cert_secret_id": schema.StringAttribute{
				Optional:    true,
				Description: "AWS Secrets Manager secret ID whose plaintext is the PEM client certificate. Mutually exclusive with `client_cert_path`.",
			},
			"client_key_secret_id": schema.StringAttribute{
				Optional:    true,
				Description: "AWS Secrets Manager secret ID whose plaintext is the PEM client private key. Mutually exclusive with `client_key_path`.",
				Sensitive:   true,
			},
			"ca_cert_secret_id": schema.StringAttribute{
				Optional:    true,
				Description: "AWS Secrets Manager secret ID whose plaintext is the CA chain PEM. Mutually exclusive with `ca_cert_path`.",
			},
			"aws_region": schema.StringAttribute{
				Optional:    true,
				Description: "AWS region for Secrets Manager calls. Falls back to the AWS SDK's standard config chain (AWS_REGION, ~/.aws/config, etc.). Ignored if no `*_secret_id` fields are set.",
			},
			"aws_access_key_id": schema.StringAttribute{
				Optional:    true,
				Description: "AWS access key ID for Secrets Manager calls. If set, must be paired with `aws_secret_access_key`. Falls back to the AWS SDK's standard credential chain. Prefer env vars / IAM roles for production.",
				Sensitive:   true,
			},
			"aws_secret_access_key": schema.StringAttribute{
				Optional:    true,
				Description: "AWS secret access key for Secrets Manager calls. If set, must be paired with `aws_access_key_id`. Falls back to the AWS SDK's standard credential chain. Prefer env vars / IAM roles for production.",
				Sensitive:   true,
			},
		},
	}
}

func (p *combineProvider) Configure(ctx context.Context, req provider.ConfigureRequest, resp *provider.ConfigureResponse) {
	var cfg combineProviderModel
	resp.Diagnostics.Append(req.Config.Get(ctx, &cfg)...)
	if resp.Diagnostics.HasError() {
		return
	}

	endpointPath := stringOrEnv(cfg.Endpoint, "COMBINE_TAP_ENDPOINT")
	certPath := stringOrEnv(cfg.ClientCertPath, "COMBINE_TAP_CLIENT_CERT")
	keyPath := stringOrEnv(cfg.ClientKeyPath, "COMBINE_TAP_CLIENT_KEY")
	caPath := stringOrEnv(cfg.CACertPath, "COMBINE_TAP_CA_CERT")

	endpointSecret := stringOrZero(cfg.EndpointSecretID)
	certSecret := stringOrZero(cfg.ClientCertSecretID)
	keySecret := stringOrZero(cfg.ClientKeySecretID)
	caSecret := stringOrZero(cfg.CACertSecretID)

	checkExclusive(resp, "endpoint", endpointPath, "endpoint_secret_id", endpointSecret)
	checkExclusive(resp, "client_cert_path", certPath, "client_cert_secret_id", certSecret)
	checkExclusive(resp, "client_key_path", keyPath, "client_key_secret_id", keySecret)
	checkExclusive(resp, "ca_cert_path", caPath, "ca_cert_secret_id", caSecret)
	if resp.Diagnostics.HasError() {
		return
	}

	clientCfg := client.Config{
		Endpoint:       endpointPath,
		ClientCertPath: certPath,
		ClientKeyPath:  keyPath,
		CACertPath:     caPath,
	}

	// Fetch any *_secret_id values from AWS Secrets Manager. We build the SM
	// client lazily — only if at least one secret_id is set — so users who
	// don't opt in aren't forced to have AWS credentials configured.
	if endpointSecret != "" || certSecret != "" || keySecret != "" || caSecret != "" {
		accessKey := stringOrZero(cfg.AWSAccessKeyID)
		secretKey := stringOrZero(cfg.AWSSecretAccessKey)
		if (accessKey == "") != (secretKey == "") {
			resp.Diagnostics.AddError("Incomplete AWS static credentials",
				"`aws_access_key_id` and `aws_secret_access_key` must be set together or both left unset.")
			return
		}

		sm, err := newSecretsManagerClient(ctx, stringOrZero(cfg.AWSRegion), accessKey, secretKey)
		if err != nil {
			resp.Diagnostics.AddError("Failed to initialize AWS Secrets Manager client",
				"Provider was configured with one or more *_secret_id fields but the AWS SDK could not load credentials. "+
					"Ensure AWS credentials are available (env, shared config, IAM role) and a region is set "+
					"(aws_region, AWS_REGION, or ~/.aws/config).\n\nUnderlying error: "+err.Error())
			return
		}

		if endpointSecret != "" {
			v, err := fetchSecretString(ctx, sm, endpointSecret)
			if err != nil {
				resp.Diagnostics.AddAttributeError(path.Root("endpoint_secret_id"), "Failed to fetch endpoint secret", err.Error())
			}
			clientCfg.Endpoint = v
		}
		if certSecret != "" {
			v, err := fetchSecretString(ctx, sm, certSecret)
			if err != nil {
				resp.Diagnostics.AddAttributeError(path.Root("client_cert_secret_id"), "Failed to fetch client cert secret", err.Error())
			}
			clientCfg.ClientCertPEM = []byte(v)
		}
		if keySecret != "" {
			v, err := fetchSecretString(ctx, sm, keySecret)
			if err != nil {
				resp.Diagnostics.AddAttributeError(path.Root("client_key_secret_id"), "Failed to fetch client key secret", err.Error())
			}
			clientCfg.ClientKeyPEM = []byte(v)
		}
		if caSecret != "" {
			v, err := fetchSecretString(ctx, sm, caSecret)
			if err != nil {
				resp.Diagnostics.AddAttributeError(path.Root("ca_cert_secret_id"), "Failed to fetch CA cert secret", err.Error())
			}
			clientCfg.CACertPEM = []byte(v)
		}
		if resp.Diagnostics.HasError() {
			return
		}
	}

	if clientCfg.Endpoint == "" {
		resp.Diagnostics.AddAttributeError(path.Root("endpoint"), "Missing TAP endpoint",
			"Set `endpoint`, `endpoint_secret_id`, or COMBINE_TAP_ENDPOINT.")
	}
	if clientCfg.ClientCertPath == "" && len(clientCfg.ClientCertPEM) == 0 {
		resp.Diagnostics.AddAttributeError(path.Root("client_cert_path"), "Missing client certificate",
			"Set `client_cert_path`, `client_cert_secret_id`, or COMBINE_TAP_CLIENT_CERT.")
	}
	if clientCfg.ClientKeyPath == "" && len(clientCfg.ClientKeyPEM) == 0 {
		resp.Diagnostics.AddAttributeError(path.Root("client_key_path"), "Missing client private key",
			"Set `client_key_path`, `client_key_secret_id`, or COMBINE_TAP_CLIENT_KEY.")
	}
	if resp.Diagnostics.HasError() {
		return
	}

	c, err := client.New(clientCfg)
	if err != nil {
		resp.Diagnostics.AddError("Failed to build TAP API client", err.Error())
		return
	}

	resp.ResourceData = c
	resp.DataSourceData = c
}

func newSecretsManagerClient(ctx context.Context, region, accessKeyID, secretAccessKey string) (*secretsmanager.Client, error) {
	var loadOpts []func(*awsconfig.LoadOptions) error
	if region != "" {
		loadOpts = append(loadOpts, awsconfig.WithRegion(region))
	}
	if accessKeyID != "" && secretAccessKey != "" {
		loadOpts = append(loadOpts, awsconfig.WithCredentialsProvider(
			credentials.NewStaticCredentialsProvider(accessKeyID, secretAccessKey, ""),
		))
	}
	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, loadOpts...)
	if err != nil {
		return nil, err
	}
	if awsCfg.Region == "" {
		return nil, fmt.Errorf("AWS region not set — provide `aws_region` or set AWS_REGION")
	}
	return secretsmanager.NewFromConfig(awsCfg), nil
}

func fetchSecretString(ctx context.Context, sm *secretsmanager.Client, secretID string) (string, error) {
	out, err := sm.GetSecretValue(ctx, &secretsmanager.GetSecretValueInput{SecretId: &secretID})
	if err != nil {
		return "", fmt.Errorf("get secret %q: %w", secretID, err)
	}
	if out.SecretString == nil {
		return "", fmt.Errorf("secret %q has no SecretString (binary secrets are not supported)", secretID)
	}
	return *out.SecretString, nil
}

func checkExclusive(resp *provider.ConfigureResponse, pathAttr, pathVal, secretAttr, secretVal string) {
	if pathVal != "" && secretVal != "" {
		resp.Diagnostics.AddError(
			fmt.Sprintf("Conflicting configuration: %s and %s", pathAttr, secretAttr),
			fmt.Sprintf("Set either %s or %s, not both.", pathAttr, secretAttr),
		)
	}
}

func (p *combineProvider) Resources(_ context.Context) []func() resource.Resource {
	return []func() resource.Resource{
		NewUserResource,
		NewGroupResource,
		NewUserGroupMembershipResource,
		NewAwsRoleResource,
	}
}

func (p *combineProvider) DataSources(_ context.Context) []func() datasource.DataSource {
	return nil
}

func stringOrEnv(v types.String, envKey string) string {
	if !v.IsNull() && !v.IsUnknown() {
		return v.ValueString()
	}
	return os.Getenv(envKey)
}

func stringOrZero(v types.String) string {
	if v.IsNull() || v.IsUnknown() {
		return ""
	}
	return v.ValueString()
}
