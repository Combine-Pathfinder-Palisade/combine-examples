package client

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type Config struct {
	Endpoint string

	// For each cert/key/CA: either the *Path or *PEM field may be set. If both are
	// set the PEM bytes win — the path form exists for the simple filesystem case;
	// PEM bytes let callers source material from Secrets Manager, Vault, etc.
	ClientCertPath string
	ClientKeyPath  string
	CACertPath     string
	ClientCertPEM  []byte
	ClientKeyPEM   []byte
	CACertPEM      []byte
}

type Client struct {
	http     *http.Client
	endpoint string
}

func New(cfg Config) (*Client, error) {
	if cfg.Endpoint == "" {
		return nil, fmt.Errorf("endpoint is required")
	}
	certPEM, err := loadPEM("client cert", cfg.ClientCertPEM, cfg.ClientCertPath)
	if err != nil {
		return nil, err
	}
	keyPEM, err := loadPEM("client key", cfg.ClientKeyPEM, cfg.ClientKeyPath)
	if err != nil {
		return nil, err
	}
	if len(certPEM) == 0 || len(keyPEM) == 0 {
		return nil, fmt.Errorf("client cert and key are required (path or PEM)")
	}

	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("load client keypair: %w", err)
	}

	tlsCfg := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	caPEM, err := loadPEM("CA cert", cfg.CACertPEM, cfg.CACertPath)
	if err != nil {
		return nil, err
	}
	if len(caPEM) > 0 {
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(caPEM) {
			return nil, fmt.Errorf("ca cert did not contain any valid PEM certificates")
		}
		tlsCfg.RootCAs = pool
	}

	return &Client{
		http: &http.Client{
			Transport: &http.Transport{TLSClientConfig: tlsCfg},
			Timeout:   30 * time.Second,
		},
		endpoint: strings.TrimRight(cfg.Endpoint, "/"),
	}, nil
}

// loadPEM resolves PEM material from inline bytes (preferred) or a filesystem
// path. Returns nil bytes (and no error) when neither is set so callers can
// treat the absence as "not configured".
func loadPEM(label string, inline []byte, path string) ([]byte, error) {
	if len(inline) > 0 {
		return inline, nil
	}
	if path == "" {
		return nil, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", label, err)
	}
	return b, nil
}

// APIError is returned for any non-2xx response.
type APIError struct {
	Status int
	Method string
	Path   string
	Body   string
}

func (e *APIError) Error() string {
	return fmt.Sprintf("TAP API %s %s: status %d: %s", e.Method, e.Path, e.Status, e.Body)
}

// NotFound reports whether err is a 404 from the TAP API.
func NotFound(err error) bool {
	var apiErr *APIError
	if !errorsAs(err, &apiErr) {
		return false
	}
	return apiErr.Status == http.StatusNotFound
}

// errorsAs is a tiny local shim to avoid pulling errors in this file's imports
// just for one call site. The std lib `errors.As` would work equivalently.
func errorsAs(err error, target **APIError) bool {
	for err != nil {
		if e, ok := err.(*APIError); ok {
			*target = e
			return true
		}
		type unwrapper interface{ Unwrap() error }
		u, ok := err.(unwrapper)
		if !ok {
			return false
		}
		err = u.Unwrap()
	}
	return false
}

func (c *Client) do(ctx context.Context, method, path string, body, out any) error {
	var reqBody io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return fmt.Errorf("marshal request body: %w", err)
		}
		reqBody = bytes.NewReader(buf)
	}

	u, err := url.JoinPath(c.endpoint, path)
	if err != nil {
		return fmt.Errorf("build url: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, method, u, reqBody)
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("X-Requested-By", "terraform-provider-combine")

	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("request: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &APIError{Status: resp.StatusCode, Method: method, Path: path, Body: string(respBody)}
	}

	if out == nil || len(respBody) == 0 {
		return nil
	}
	if err := json.Unmarshal(respBody, out); err != nil {
		return fmt.Errorf("decode response: %w", err)
	}
	return nil
}
