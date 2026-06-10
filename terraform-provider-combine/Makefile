BINARY := terraform-provider-combine
VERSION := 0.0.1-dev
HOSTNAME := registry.terraform.io
NAMESPACE := combine-pathfinder-palisade
NAME := combine

OS_ARCH := $(shell go env GOOS)_$(shell go env GOARCH)
INSTALL_DIR := $(HOME)/.terraform.d/plugins/$(HOSTNAME)/$(NAMESPACE)/$(NAME)/$(VERSION)/$(OS_ARCH)

.PHONY: build install test testacc fmt vet tidy clean

build:
	go build -o $(BINARY) .

install: build
	mkdir -p $(INSTALL_DIR)
	mv $(BINARY) $(INSTALL_DIR)/

test:
	go test ./... -race -cover

# Acceptance tests hit a real TAP backend. Run `start-tap` first.
# Env required: COMBINE_TAP_ENDPOINT, COMBINE_TAP_CLIENT_CERT, COMBINE_TAP_CLIENT_KEY, COMBINE_TAP_CA_CERT
testacc:
	TF_ACC=1 go test ./... -v -timeout 30m

fmt:
	go fmt ./...

vet:
	go vet ./...

tidy:
	go mod tidy

clean:
	rm -f $(BINARY)
	rm -rf dist/
