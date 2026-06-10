package client

import (
	"context"
	"errors"
)

type Group struct {
	GroupID     string   `json:"groupId,omitempty"`
	Name        string   `json:"name"`
	Description string   `json:"description,omitempty"`
	AccountIDs  []string `json:"accountIds,omitempty"`
	CIDRBlocks  []string `json:"cidrBlocks,omitempty"`
	VPCIDs      []string `json:"vpcIds,omitempty"`
	CreatedDate string   `json:"createdDate,omitempty"`
	UpdatedDate string   `json:"updatedDate,omitempty"`
}

// TODO(v1): implement against /api/v1/groups.
func (c *Client) CreateGroup(ctx context.Context, g *Group) (*Group, error) {
	return nil, errors.New("CreateGroup not implemented")
}

func (c *Client) GetGroup(ctx context.Context, groupID string) (*Group, error) {
	return nil, errors.New("GetGroup not implemented")
}

func (c *Client) UpdateGroup(ctx context.Context, groupID string, g *Group) (*Group, error) {
	return nil, errors.New("UpdateGroup not implemented")
}

func (c *Client) DeleteGroup(ctx context.Context, groupID string) error {
	return errors.New("DeleteGroup not implemented")
}
