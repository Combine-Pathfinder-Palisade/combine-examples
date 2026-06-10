package provider

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/combine-pathfinder-palisade/terraform-provider-combine/internal/client"
	"github.com/hashicorp/terraform-plugin-framework/diag"
	"github.com/hashicorp/terraform-plugin-framework/path"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/booldefault"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var (
	_ resource.Resource                = (*userResource)(nil)
	_ resource.ResourceWithConfigure   = (*userResource)(nil)
	_ resource.ResourceWithImportState = (*userResource)(nil)
)

func NewUserResource() resource.Resource {
	return &userResource{}
}

type userResource struct {
	client *client.Client
}

type userModel struct {
	ID                   types.String `tfsdk:"id"`
	Email                types.String `tfsdk:"email"`
	FullName             types.String `tfsdk:"full_name"`
	UserRole             types.String `tfsdk:"user_role"`
	Active               types.Bool   `tfsdk:"active"`
	AwsRoleIDs           types.Set    `tfsdk:"aws_role_ids"`
	BundlePath           types.String `tfsdk:"bundle_path"`
	CommonName           types.String `tfsdk:"common_name"`
	BundleOutputPath     types.String `tfsdk:"bundle_output_path"`
	BundleURL            types.String `tfsdk:"bundle_url"`
	LastLoginDate        types.String `tfsdk:"last_login_date"`
	LastConsoleLoginDate types.String `tfsdk:"last_console_login_date"`
}

func (r *userResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_tap_user"
}

func (r *userResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "A Combine TAP user.",
		Attributes: map[string]schema.Attribute{
			"id": schema.StringAttribute{
				Computed:    true,
				Description: "Backend-assigned numeric user ID (stringified).",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"email": schema.StringAttribute{
				Required:    true,
				Description: "User email. Treated as immutable; changes force replacement.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"full_name": schema.StringAttribute{
				Required:    true,
				Description: "Display name.",
			},
			"user_role": schema.StringAttribute{
				Required:    true,
				Description: "Role (e.g. `user`, `admin`, `super_admin`). Server enforces who may create which role.",
			},
			"active": schema.BoolAttribute{
				Optional:    true,
				Computed:    true,
				Default:     booldefault.StaticBool(true),
				Description: "Whether the user is active. Defaults to true.",
			},
			"aws_role_ids": schema.SetAttribute{
				ElementType: types.StringType,
				Optional:    true,
				Computed:    true,
				Description: "AWS role IDs attached to this user. Stored inline because the TAP API only accepts whole-list updates.",
			},
			"bundle_path": schema.StringAttribute{
				Optional:    true,
				Computed:    true,
				Description: "Server-side bundle path. Silently ignored by PUT; changes force replacement.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"common_name": schema.StringAttribute{
				Optional:    true,
				Computed:    true,
				Description: "Certificate common name override. Silently ignored by PUT; changes force replacement.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"bundle_output_path": schema.StringAttribute{
				Optional: true,
				Description: "If set, the provider downloads the user's cert bundle to this path on create. " +
					"The bundle bytes are never stored in Terraform state.",
			},
			"bundle_url": schema.StringAttribute{
				Computed: true,
				Description: "Short-lived presigned URL for the user's cert bundle. Set on create and not refreshed " +
					"by subsequent plans; run `terraform refresh` to fetch a fresh URL.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"last_login_date": schema.StringAttribute{
				Computed:    true,
				Description: "Read-only: last API login.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"last_console_login_date": schema.StringAttribute{
				Computed:    true,
				Description: "Read-only: last console login.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
		},
	}
}

func (r *userResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*client.Client)
	if !ok {
		resp.Diagnostics.AddError("Unexpected provider data", fmt.Sprintf("got %T, expected *client.Client", req.ProviderData))
		return
	}
	r.client = c
}

func (r *userResource) Create(ctx context.Context, req resource.CreateRequest, resp *resource.CreateResponse) {
	var plan userModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	if resp.Diagnostics.HasError() {
		return
	}

	roleIDs, diags := setOfStringToInt64s(ctx, plan.AwsRoleIDs)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}

	body := &client.User{
		Email:      plan.Email.ValueString(),
		FullName:   plan.FullName.ValueString(),
		UserRole:   plan.UserRole.ValueString(),
		Active:     plan.Active.ValueBool(),
		AwsRoles:   roleIDs,
		BundlePath: plan.BundlePath.ValueString(),
		CommonName: plan.CommonName.ValueString(),
	}

	created, err := r.client.CreateUser(ctx, body)
	if err != nil {
		resp.Diagnostics.AddError("Failed to create TAP user", err.Error())
		return
	}

	bundleURL, err := r.client.GenerateBundleURL(ctx, created.ID)
	if err != nil {
		resp.Diagnostics.AddWarning("Failed to fetch bundle URL", err.Error())
	}

	if !plan.BundleOutputPath.IsNull() && !plan.BundleOutputPath.IsUnknown() && bundleURL != "" {
		if err := downloadBundle(ctx, bundleURL, plan.BundleOutputPath.ValueString()); err != nil {
			resp.Diagnostics.AddWarning("Failed to download cert bundle", err.Error())
		}
	}

	state := userToModel(created, plan.BundleOutputPath, bundleURL)
	resp.Diagnostics.Append(resp.State.Set(ctx, state)...)
}

func (r *userResource) Read(ctx context.Context, req resource.ReadRequest, resp *resource.ReadResponse) {
	var state userModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	got, err := r.client.GetUser(ctx, state.ID.ValueString())
	if err != nil {
		if client.NotFound(err) {
			resp.State.RemoveResource(ctx)
			return
		}
		resp.Diagnostics.AddError("Failed to read TAP user", err.Error())
		return
	}

	// Preserve bundle_url and bundle_output_path from prior state — neither is
	// re-derivable from the API on refresh.
	next := userToModel(got, state.BundleOutputPath, state.BundleURL.ValueString())
	resp.Diagnostics.Append(resp.State.Set(ctx, next)...)
}

func (r *userResource) Update(ctx context.Context, req resource.UpdateRequest, resp *resource.UpdateResponse) {
	var plan, state userModel
	resp.Diagnostics.Append(req.Plan.Get(ctx, &plan)...)
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	id, err := strconv.ParseInt(state.ID.ValueString(), 10, 64)
	if err != nil {
		resp.Diagnostics.AddError("Bad state: id is not an int64", state.ID.ValueString())
		return
	}

	roleIDs, diags := setOfStringToInt64s(ctx, plan.AwsRoleIDs)
	resp.Diagnostics.Append(diags...)
	if resp.Diagnostics.HasError() {
		return
	}

	fullName := plan.FullName.ValueString()
	userRole := plan.UserRole.ValueString()
	active := plan.Active.ValueBool()
	patch := &client.UserUpdate{
		FullName: &fullName,
		UserRole: &userRole,
		Active:   &active,
		AwsRoles: &roleIDs,
	}

	updated, err := r.client.UpdateUser(ctx, id, patch)
	if err != nil {
		resp.Diagnostics.AddError("Failed to update TAP user", err.Error())
		return
	}

	next := userToModel(updated, plan.BundleOutputPath, state.BundleURL.ValueString())
	resp.Diagnostics.Append(resp.State.Set(ctx, next)...)
}

func (r *userResource) Delete(ctx context.Context, req resource.DeleteRequest, resp *resource.DeleteResponse) {
	var state userModel
	resp.Diagnostics.Append(req.State.Get(ctx, &state)...)
	if resp.Diagnostics.HasError() {
		return
	}

	id, err := strconv.ParseInt(state.ID.ValueString(), 10, 64)
	if err != nil {
		resp.Diagnostics.AddError("Bad state: id is not an int64", state.ID.ValueString())
		return
	}

	if err := r.client.DeleteUser(ctx, id); err != nil {
		if client.NotFound(err) {
			return
		}
		resp.Diagnostics.AddError("Failed to delete TAP user", err.Error())
		return
	}
}

// ImportState accepts either a numeric ID or an email address. The TAP GET
// endpoint accepts both; we delegate the lookup to the server.
func (r *userResource) ImportState(ctx context.Context, req resource.ImportStateRequest, resp *resource.ImportStateResponse) {
	got, err := r.client.GetUser(ctx, req.ID)
	if err != nil {
		resp.Diagnostics.AddError("Failed to import TAP user", err.Error())
		return
	}
	resp.Diagnostics.Append(resp.State.SetAttribute(ctx, path.Root("id"), strconv.FormatInt(got.ID, 10))...)
}

func userToModel(u *client.User, bundleOutputPath types.String, bundleURL string) *userModel {
	m := &userModel{
		ID:                   types.StringValue(strconv.FormatInt(u.ID, 10)),
		Email:                types.StringValue(u.Email),
		FullName:             types.StringValue(u.FullName),
		UserRole:             types.StringValue(u.UserRole),
		Active:               types.BoolValue(u.Active),
		BundlePath:           stringOrNull(u.BundlePath),
		CommonName:           stringOrNull(u.CommonName),
		BundleOutputPath:     bundleOutputPath,
		LastLoginDate:        stringOrNull(u.LastLoginDate),
		LastConsoleLoginDate: stringOrNull(u.LastConsoleLoginDate),
	}
	if bundleURL != "" {
		m.BundleURL = types.StringValue(bundleURL)
	} else {
		m.BundleURL = types.StringNull()
	}

	ids := make([]string, 0, len(u.AwsRoles))
	for _, id := range u.AwsRoles {
		ids = append(ids, strconv.FormatInt(id, 10))
	}
	set, _ := types.SetValueFrom(context.Background(), types.StringType, ids)
	m.AwsRoleIDs = set
	return m
}

func stringOrNull(s string) types.String {
	if s == "" {
		return types.StringNull()
	}
	return types.StringValue(s)
}

func setOfStringToInt64s(ctx context.Context, set types.Set) ([]int64, diag.Diagnostics) {
	var diags diag.Diagnostics
	out := []int64{}
	if set.IsNull() || set.IsUnknown() {
		return out, diags
	}
	var asStrings []string
	diags.Append(set.ElementsAs(ctx, &asStrings, false)...)
	if diags.HasError() {
		return nil, diags
	}
	for _, s := range asStrings {
		v, err := strconv.ParseInt(s, 10, 64)
		if err != nil {
			diags.AddError("invalid AWS role id", fmt.Sprintf("expected numeric id, got %q", s))
			return nil, diags
		}
		out = append(out, v)
	}
	return out, diags
}

// downloadBundle GETs the presigned URL and writes the body to outputPath.
// Uses http.DefaultClient because the presigned URL is a public S3-style URL —
// the mTLS client must NOT be used here (it would present client certs to S3).
func downloadBundle(ctx context.Context, presignedURL, outputPath string) error {
	req, err := http.NewRequestWithContext(ctx, "GET", presignedURL, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return fmt.Errorf("download bundle: status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	// Create the parent directory if the operator pointed bundle_output_path at a
	// path whose dir doesn't exist yet (O_CREATE makes the file, not the dir).
	if dir := filepath.Dir(outputPath); dir != "" {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return fmt.Errorf("create bundle output dir %q: %w", dir, err)
		}
	}
	f, err := os.OpenFile(outputPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := io.Copy(f, resp.Body); err != nil {
		return err
	}
	return nil
}
