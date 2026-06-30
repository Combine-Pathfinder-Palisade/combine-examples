package main

import "testing"

func TestRewriteImage(t *testing.T) {
	isoRegion = "us-iso-east-1"
	isoSuffix = "c2s.ic.gov"
	allowedAccounts = map[string]bool{"602401143452": true}

	cases := []struct {
		name string
		in   string
		want string
		ok   bool
	}{
		{
			"tagged addon image is rewritten to ISO-form",
			"602401143452.dkr.ecr.us-east-1.amazonaws.com/eks/coredns:v1.13.2-eksbuild.10",
			"602401143452.dkr.ecr.us-iso-east-1.c2s.ic.gov/eks/coredns:v1.13.2-eksbuild.10",
			true,
		},
		{
			"digest ref and nested repo path are preserved",
			"602401143452.dkr.ecr.us-east-1.amazonaws.com/amazon/aws-network-policy-agent@sha256:abc123",
			"602401143452.dkr.ecr.us-iso-east-1.c2s.ic.gov/amazon/aws-network-policy-agent@sha256:abc123",
			true,
		},
		{
			"any commercial source region maps to the configured ISO region",
			"602401143452.dkr.ecr.eu-west-1.amazonaws.com/eks/kube-proxy:v1.30.0",
			"602401143452.dkr.ecr.us-iso-east-1.c2s.ic.gov/eks/kube-proxy:v1.30.0",
			true,
		},
		{
			"non-allow-listed account is left untouched",
			"999999999999.dkr.ecr.us-east-1.amazonaws.com/team/app:1.0",
			"999999999999.dkr.ecr.us-east-1.amazonaws.com/team/app:1.0",
			false,
		},
		{
			"non-ECR registry is left untouched (e.g. community add-on)",
			"registry.k8s.io/metrics-server/metrics-server:v0.7.2",
			"registry.k8s.io/metrics-server/metrics-server:v0.7.2",
			false,
		},
		{
			"already ISO-form image is not rewritten again",
			"602401143452.dkr.ecr.us-iso-east-1.c2s.ic.gov/eks/coredns:v1.13.2-eksbuild.10",
			"602401143452.dkr.ecr.us-iso-east-1.c2s.ic.gov/eks/coredns:v1.13.2-eksbuild.10",
			false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := rewriteImage(c.in)
			if got != c.want || ok != c.ok {
				t.Errorf("rewriteImage(%q) = (%q, %v); want (%q, %v)", c.in, got, ok, c.want, c.ok)
			}
		})
	}
}

func TestRewriteImage_EmptyAllowListMatchesAnyEcr(t *testing.T) {
	isoRegion = "us-iso-east-1"
	isoSuffix = "c2s.ic.gov"
	allowedAccounts = map[string]bool{} // empty => any commercial dkr.ecr host

	in := "123456789012.dkr.ecr.us-west-2.amazonaws.com/whatever:tag"
	want := "123456789012.dkr.ecr.us-iso-east-1.c2s.ic.gov/whatever:tag"
	if got, ok := rewriteImage(in); got != want || !ok {
		t.Errorf("rewriteImage(%q) = (%q, %v); want (%q, true)", in, got, ok, want)
	}
}
