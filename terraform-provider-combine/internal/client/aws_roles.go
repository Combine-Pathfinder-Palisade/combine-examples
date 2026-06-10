package client

import (
	"context"
	"errors"
)

// AwsRolePair mirrors the value/alias/description triple TAP uses for each
// of {account, agency, role}.
type AwsRolePair struct {
	Value            string `json:"value"`
	ValueAlias       string `json:"valueAlias,omitempty"`
	ValueDescription string `json:"valueDescription,omitempty"`
}

type AwsRole struct {
	ID          int64       `json:"id,omitempty"`
	Environment string      `json:"environment"`
	DefaultRole bool        `json:"defaultRole"`
	Account     AwsRolePair `json:"account"`
	Agency      AwsRolePair `json:"agency"`
	Role        AwsRolePair `json:"role"`
}

// TODO(v1): implement against /api/v1/aws-roles.
func (c *Client) CreateAwsRole(ctx context.Context, r *AwsRole) (*AwsRole, error) {
	return nil, errors.New("CreateAwsRole not implemented")
}

func (c *Client) GetAwsRole(ctx context.Context, id int64) (*AwsRole, error) {
	return nil, errors.New("GetAwsRole not implemented")
}

func (c *Client) UpdateAwsRole(ctx context.Context, id int64, r *AwsRole) (*AwsRole, error) {
	return nil, errors.New("UpdateAwsRole not implemented")
}

func (c *Client) DeleteAwsRole(ctx context.Context, id int64) error {
	return errors.New("DeleteAwsRole not implemented")
}
