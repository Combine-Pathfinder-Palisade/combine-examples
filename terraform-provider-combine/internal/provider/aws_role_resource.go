package provider

import (
	"context"
	"fmt"

	"github.com/combine-pathfinder-palisade/terraform-provider-combine/internal/client"
	"github.com/hashicorp/terraform-plugin-framework/resource"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/planmodifier"
	"github.com/hashicorp/terraform-plugin-framework/resource/schema/stringplanmodifier"
	"github.com/hashicorp/terraform-plugin-framework/types"
)

var (
	_ resource.Resource              = (*awsRoleResource)(nil)
	_ resource.ResourceWithConfigure = (*awsRoleResource)(nil)
)

func NewAwsRoleResource() resource.Resource {
	return &awsRoleResource{}
}

type awsRoleResource struct {
	client *client.Client
}

type awsRolePairModel struct {
	Value            types.String `tfsdk:"value"`
	ValueAlias       types.String `tfsdk:"value_alias"`
	ValueDescription types.String `tfsdk:"value_description"`
}

type awsRoleModel struct {
	ID          types.String      `tfsdk:"id"`
	Environment types.String      `tfsdk:"environment"`
	DefaultRole types.Bool        `tfsdk:"default_role"`
	Account     *awsRolePairModel `tfsdk:"account"`
	Agency      *awsRolePairModel `tfsdk:"agency"`
	Role        *awsRolePairModel `tfsdk:"role"`
}

func (r *awsRoleResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_tap_aws_role"
}

func (r *awsRoleResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	pairAttrs := map[string]schema.Attribute{
		"value": schema.StringAttribute{
			Required: true,
		},
		"value_alias": schema.StringAttribute{
			Optional: true,
			Computed: true,
		},
		"value_description": schema.StringAttribute{
			Optional: true,
			Computed: true,
		},
	}

	resp.Schema = schema.Schema{
		Description: "A Combine TAP AWS role (account/agency/role triple). STUB — CRUD not yet implemented.",
		Attributes: map[string]schema.Attribute{
			"id": schema.StringAttribute{
				Computed:    true,
				Description: "Backend-assigned numeric ID.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"environment": schema.StringAttribute{
				Required: true,
			},
			"default_role": schema.BoolAttribute{
				Optional: true,
				Computed: true,
			},
			"account": schema.SingleNestedAttribute{
				Required:   true,
				Attributes: pairAttrs,
			},
			"agency": schema.SingleNestedAttribute{
				Required:   true,
				Attributes: pairAttrs,
			},
			"role": schema.SingleNestedAttribute{
				Required:   true,
				Attributes: pairAttrs,
			},
		},
	}
}

func (r *awsRoleResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
	if req.ProviderData == nil {
		return
	}
	c, ok := req.ProviderData.(*client.Client)
	if !ok {
		resp.Diagnostics.AddError("Unexpected provider data", fmt.Sprintf("got %T", req.ProviderData))
		return
	}
	r.client = c
}

func (r *awsRoleResource) Create(_ context.Context, _ resource.CreateRequest, resp *resource.CreateResponse) {
	resp.Diagnostics.AddError("Not implemented", "combine_tap_aws_role Create is not yet wired up.")
}

func (r *awsRoleResource) Read(_ context.Context, _ resource.ReadRequest, resp *resource.ReadResponse) {
	resp.Diagnostics.AddError("Not implemented", "combine_tap_aws_role Read is not yet wired up.")
}

func (r *awsRoleResource) Update(_ context.Context, _ resource.UpdateRequest, resp *resource.UpdateResponse) {
	resp.Diagnostics.AddError("Not implemented", "combine_tap_aws_role Update is not yet wired up.")
}

func (r *awsRoleResource) Delete(_ context.Context, _ resource.DeleteRequest, resp *resource.DeleteResponse) {
	resp.Diagnostics.AddError("Not implemented", "combine_tap_aws_role Delete is not yet wired up.")
}
