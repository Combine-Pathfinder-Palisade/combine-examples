# Cross-compile the binary on the NATIVE build arch (no qemu) and target the node arch via GOARCH.
# Running the target-arch Go toolchain under qemu (e.g. building amd64 on an arm64 Mac) crashes the
# Go runtime; cross-compiling natively avoids emulation entirely. Requires BuildKit (Docker default)
# so $BUILDPLATFORM / $TARGETOS / $TARGETARCH are populated.
FROM --platform=$BUILDPLATFORM golang:1.23 AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath -ldflags="-s -w" -o /webhook .

# Minimal runtime. distroless/static must itself be pullable by your build host; if it isn't,
# `FROM scratch` also works (the binary is fully static) — you'd lose the nonroot user, so set
# runAsUser explicitly in the Deployment (it already does: 65532).
FROM gcr.io/distroless/static:nonroot
COPY --from=build /webhook /webhook
USER nonroot:nonroot
ENTRYPOINT ["/webhook"]
