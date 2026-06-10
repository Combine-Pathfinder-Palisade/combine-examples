package client

import (
	"context"
	"fmt"
	"net/url"
)

// User mirrors the TAP API's user JSON shape. Field names match the wire
// format (camelCase). Fields the API silently ignores on PUT (commonName,
// bundlePath) are kept here so we can send them on POST.
type User struct {
	ID                   int64   `json:"id,omitempty"`
	Email                string  `json:"email"`
	FullName             string  `json:"fullName"`
	UserRole             string  `json:"userRole"`
	Active               bool    `json:"active"`
	AwsRoles             []int64 `json:"awsRoles"`
	BundlePath           string  `json:"bundlePath,omitempty"`
	CommonName           string  `json:"commonName,omitempty"`
	LastLoginDate        string  `json:"lastLoginDate,omitempty"`
	LastConsoleLoginDate string  `json:"lastConsoleLoginDate,omitempty"`
	StorageVersion       string  `json:"storageVersion,omitempty"`
	IsServer             bool    `json:"isServer,omitempty"`
}

// UserUpdate is the subset of fields the TAP PUT handler actually persists.
// Sending other fields is accepted but silently ignored; we send only what
// the server will honor to keep diffs honest.
type UserUpdate struct {
	Email    *string  `json:"email,omitempty"`
	FullName *string  `json:"fullName,omitempty"`
	UserRole *string  `json:"userRole,omitempty"`
	Active   *bool    `json:"active,omitempty"`
	AwsRoles *[]int64 `json:"awsRoles,omitempty"`
}

// userEnvelope matches the TAP user CRUD response wrapper. POST/GET/PUT all
// return `{"data": <User>, ...}`; only the user object is interesting here.
type userEnvelope struct {
	Data User `json:"data"`
}

func (c *Client) CreateUser(ctx context.Context, u *User) (*User, error) {
	var env userEnvelope
	if err := c.do(ctx, "POST", "/api/v1/users", u, &env); err != nil {
		return nil, err
	}
	return &env.Data, nil
}

// GetUser fetches by numeric ID or by email. The TAP endpoint accepts both;
// callers pass whichever they have.
func (c *Client) GetUser(ctx context.Context, idOrEmail string) (*User, error) {
	var env userEnvelope
	path := fmt.Sprintf("/api/v1/users/%s", url.PathEscape(idOrEmail))
	if err := c.do(ctx, "GET", path, nil, &env); err != nil {
		return nil, err
	}
	return &env.Data, nil
}

func (c *Client) UpdateUser(ctx context.Context, id int64, patch *UserUpdate) (*User, error) {
	var env userEnvelope
	path := fmt.Sprintf("/api/v1/users/%d", id)
	if err := c.do(ctx, "PUT", path, patch, &env); err != nil {
		return nil, err
	}
	return &env.Data, nil
}

func (c *Client) DeleteUser(ctx context.Context, id int64) error {
	path := fmt.Sprintf("/api/v1/users/%d", id)
	return c.do(ctx, "DELETE", path, nil, nil)
}

type bundleURLResponse struct {
	URL string `json:"url"`
}

// GenerateBundleURL asks TAP for a short-lived presigned URL for the user's
// certificate bundle. The exact response shape may differ; adjust the
// `bundleURLResponse` struct to match what the server returns.
func (c *Client) GenerateBundleURL(ctx context.Context, id int64) (string, error) {
	var resp bundleURLResponse
	path := fmt.Sprintf("/api/v1/users/%d/generateBundleUrl", id)
	if err := c.do(ctx, "GET", path, nil, &resp); err != nil {
		return "", err
	}
	return resp.URL, nil
}
