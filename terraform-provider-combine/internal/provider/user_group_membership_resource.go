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
	_ resource.Resource              = (*userGroupMembershipResource)(nil)
	_ resource.ResourceWithConfigure = (*userGroupMembershipResource)(nil)
)

func NewUserGroupMembershipResource() resource.Resource {
	return &userGroupMembershipResource{}
}

type userGroupMembershipResource struct {
	client *client.Client
}

type userGroupMembershipModel struct {
	ID      types.String `tfsdk:"id"`
	GroupID types.String `tfsdk:"group_id"`
	UserID  types.String `tfsdk:"user_id"`
}

func (r *userGroupMembershipResource) Metadata(_ context.Context, req resource.MetadataRequest, resp *resource.MetadataResponse) {
	resp.TypeName = req.ProviderTypeName + "_tap_user_group_membership"
}

func (r *userGroupMembershipResource) Schema(_ context.Context, _ resource.SchemaRequest, resp *resource.SchemaResponse) {
	resp.Schema = schema.Schema{
		Description: "Membership of a TAP user in a TAP group. STUB — CRUD not yet implemented.",
		Attributes: map[string]schema.Attribute{
			"id": schema.StringAttribute{
				Computed:    true,
				Description: "Composite `<group_id>:<user_id>`.",
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.UseStateForUnknown(),
				},
			},
			"group_id": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
			"user_id": schema.StringAttribute{
				Required: true,
				PlanModifiers: []planmodifier.String{
					stringplanmodifier.RequiresReplace(),
				},
			},
		},
	}
}

func (r *userGroupMembershipResource) Configure(_ context.Context, req resource.ConfigureRequest, resp *resource.ConfigureResponse) {
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

func (r *userGroupMembershipResource) Create(_ context.Context, _ resource.CreateRequest, resp *resource.CreateResponse) {
	resp.Diagnostics.AddError("Not implemented", "combine_tap_user_group_membership Create is not yet wired up.")
}

func (r *userGroupMembershipResource) Read(_ context.Context, _ resource.ReadRequest, resp *resource.ReadResponse) {
	resp.Diagnostics.AddError("Not implemented", "combine_tap_user_group_membership Read is not yet wired up.")
}

func (r *userGroupMembershipResource) Update(_ context.Context, _ resource.UpdateRequest, resp *resource.UpdateResponse) {
	resp.Diagnostics.AddError("Not implemented", "combine_tap_user_group_membership Update is not yet wired up.")
}

func (r *userGroupMembershipResource) Delete(_ context.Context, _ resource.DeleteRequest, resp *resource.DeleteResponse) {
	resp.Diagnostics.AddError("Not implemented", "combine_tap_user_group_membership Delete is not yet wired up.")
}
