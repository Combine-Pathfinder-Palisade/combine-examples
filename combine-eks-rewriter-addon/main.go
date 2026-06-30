package main

// combine-eks-rewriter
//
// A Kubernetes mutating admission webhook that extends Combine's emulation INTO the cluster.
//
// EKS managed add-ons receive their container image references directly from the EKS managed
// control plane, which writes them straight into the add-on's workload spec — a path that never
// transits Combine, so Combine's VPC-boundary emulation can't rewrite them. The control plane
// injects the COMMERCIAL-partition ECR registry host (e.g. 602401143452.dkr.ecr.us-east-1.amazonaws.com),
// which an isolated/high-side cluster cannot resolve, reach, or authenticate against.
//
// This webhook closes that gap. On Pod creation it rewrites the commercial ECR host to the
// ISO-form host that Combine fronts (e.g. 602401143452.dkr.ecr.us-iso-east-1.c2s.ic.gov), so the
// kubelet's pull rides exactly the same path as a normal in-cluster image pull: ISO ECR API ->
// Combine (ISO token) -> Combine proxies the layers from the real upstream registry.
//
// Because it mutates at the POD level (not the Deployment/DaemonSet template), the EKS add-on
// controller can keep reconciling the workload's image back to the commercial host; every pod it
// rolls is re-mutated on CREATE.

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
)

var (
	// The emulated (ISO) region + DNS suffix Combine serves. Set per partition via env, e.g.
	// us-iso-east-1 / c2s.ic.gov  (C2S),  us-isob-east-1 / sc2s.sgov.gov  (SC2S).
	isoRegion = envOr("COMBINE_ISO_REGION", "us-iso-east-1")
	isoSuffix = envOr("COMBINE_ISO_DNS_SUFFIX", "c2s.ic.gov")

	// <12-digit account>.dkr.ecr.<region>.amazonaws.com<the rest: /repo:tag or /repo@sha256:...>
	ecrHost = regexp.MustCompile(`^(\d{12})\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(/.*)$`)

	// Optional allow list of AWS-owned EKS add-on registry accounts (COMBINE_ADDON_ECR_ACCOUNTS,
	// comma-separated). Empty => rewrite ANY commercial dkr.ecr host. Scoping it restricts the
	// webhook to AWS-owned add-on registries and never touches a customer's own images.
	allowedAccounts = splitSet(os.Getenv("COMBINE_ADDON_ECR_ACCOUNTS"))
)

// rewriteImage returns the ISO-form image and true if img is a (scoped) commercial ECR reference.
func rewriteImage(img string) (string, bool) {
	m := ecrHost.FindStringSubmatch(img)
	if m == nil {
		return img, false
	}
	account, rest := m[1], m[2]
	if len(allowedAccounts) > 0 && !allowedAccounts[account] {
		return img, false
	}
	return fmt.Sprintf("%s.dkr.ecr.%s.%s%s", account, isoRegion, isoSuffix, rest), true
}

// --- Minimal admission.k8s.io/v1 + core/v1 Pod shapes (stdlib JSON only, no k8s client deps) ---

type admissionReview struct {
	APIVersion string             `json:"apiVersion"`
	Kind       string             `json:"kind"`
	Request    *admissionRequest  `json:"request,omitempty"`
	Response   *admissionResponse `json:"response,omitempty"`
}

type admissionRequest struct {
	UID    string          `json:"uid"`
	Object json.RawMessage `json:"object"`
}

type admissionResponse struct {
	UID       string  `json:"uid"`
	Allowed   bool    `json:"allowed"`
	PatchType *string `json:"patchType,omitempty"`
	Patch     []byte  `json:"patch,omitempty"` // encoding/json base64-encodes []byte, as the API expects
}

type pod struct {
	Spec struct {
		Containers          []container `json:"containers"`
		InitContainers      []container `json:"initContainers"`
		EphemeralContainers []container `json:"ephemeralContainers"`
	} `json:"spec"`
}

type container struct {
	Image string `json:"image"`
}

type patchOp struct {
	Op    string `json:"op"`
	Path  string `json:"path"`
	Value string `json:"value"`
}

func handleMutate(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "read error", http.StatusBadRequest)
		return
	}

	var review admissionReview
	if err := json.Unmarshal(body, &review); err != nil || review.Request == nil {
		http.Error(w, "bad AdmissionReview", http.StatusBadRequest)
		return
	}

	var p pod
	_ = json.Unmarshal(review.Request.Object, &p) // best-effort; non-pods yield no patches

	var patches []patchOp
	add := func(field string, cs []container) {
		for i, c := range cs {
			if nv, ok := rewriteImage(c.Image); ok {
				patches = append(patches, patchOp{
					Op:    "replace",
					Path:  fmt.Sprintf("/spec/%s/%d/image", field, i),
					Value: nv,
				})
				log.Printf("rewrite %s[%d]: %s -> %s", field, i, c.Image, nv)
			}
		}
	}
	add("initContainers", p.Spec.InitContainers)
	add("containers", p.Spec.Containers)
	add("ephemeralContainers", p.Spec.EphemeralContainers)

	resp := admissionResponse{UID: review.Request.UID, Allowed: true}
	if len(patches) > 0 {
		pb, _ := json.Marshal(patches)
		resp.Patch = pb
		pt := "JSONPatch"
		resp.PatchType = &pt
	}

	out := admissionReview{
		APIVersion: "admission.k8s.io/v1",
		Kind:       "AdmissionReview",
		Response:   &resp,
	}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(out); err != nil {
		log.Printf("encode error: %v", err)
	}
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", handleMutate)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) })

	srv := &http.Server{
		Addr:      ":8443",
		Handler:   mux,
		TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}

	log.Printf("combine-eks-rewriter listening on :8443 (iso=%s.%s, scopedAccounts=%v)",
		isoRegion, isoSuffix, keys(allowedAccounts))
	log.Fatal(srv.ListenAndServeTLS("/tls/tls.crt", "/tls/tls.key"))
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func splitSet(s string) map[string]bool {
	m := map[string]bool{}
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			m[p] = true
		}
	}
	return m
}

func keys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}
