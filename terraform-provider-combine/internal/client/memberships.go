package client

import (
	"context"
	"errors"
)

// TODO(v1): implement against /api/v1/groups/{groupId}/members.
func (c *Client) AddGroupMember(ctx context.Context, groupID string, userID int64) error {
	return errors.New("AddGroupMember not implemented")
}

func (c *Client) RemoveGroupMember(ctx context.Context, groupID string, userID int64) error {
	return errors.New("RemoveGroupMember not implemented")
}

// HasGroupMember reports whether the user is a member of the group. Used by
// the membership resource's Read.
func (c *Client) HasGroupMember(ctx context.Context, groupID string, userID int64) (bool, error) {
	return false, errors.New("HasGroupMember not implemented")
}
