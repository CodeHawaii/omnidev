# omnidev — universal multi-language build/test sandbox image
IMAGE       ?= omnidev
LOCAL_TAG   ?= $(IMAGE):local
REGISTRY    ?= ghcr.io/codehawaii
PLATFORMS   ?= linux/amd64,linux/arm64
VERSION     ?= dev
VCS_REF     := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
BUILD_DATE  := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
BUILD_ARGS  := --build-arg VCS_REF=$(VCS_REF) --build-arg BUILD_VERSION=$(VERSION) --build-arg BUILD_DATE=$(BUILD_DATE)

.PHONY: help build build-multi push run shell smoke sandbox clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-13s\033[0m %s\n",$$1,$$2}'

build: ## Build for the host arch and load it locally as omnidev:local
	docker buildx build --load $(BUILD_ARGS) -t $(LOCAL_TAG) .

build-multi: ## Build multi-arch (cannot --load; use `push` or an --output)
	docker buildx build --platform $(PLATFORMS) $(BUILD_ARGS) -t $(REGISTRY)/$(IMAGE):$(VERSION) .

push: ## Build multi-arch and push to the registry (requires docker login)
	docker buildx build --platform $(PLATFORMS) --push $(BUILD_ARGS) \
	  -t $(REGISTRY)/$(IMAGE):$(VERSION) -t $(REGISTRY)/$(IMAGE):latest .

run: build ## Build, then drop into an interactive shell
	docker run --rm -it $(LOCAL_TAG) bash

shell: ## Interactive shell in the already-built local image
	docker run --rm -it $(LOCAL_TAG) bash

smoke: ## Print all bundled tool versions from the local image
	@docker run --rm $(LOCAL_TAG) bash -lc '\
	  echo "debian : $$(. /etc/os-release; echo $$VERSION)"; \
	  echo "python : $$(python3 --version)"; \
	  echo "uv     : $$(uv --version)"; \
	  echo "go     : $$(go version)"; \
	  echo "node   : $$(node --version)"; \
	  echo "npm    : $$(npm --version)"; \
	  echo "pnpm   : $$(pnpm --version)"; \
	  echo "yarn   : $$(yarn --version)"; \
	  echo "gcc    : $$(gcc -dumpfullversion)"; \
	  echo "make   : $$(make --version | head -1)"; \
	  echo "cmake  : $$(cmake --version | head -1)"; \
	  echo "git    : $$(git --version)"; \
	  echo "rg     : $$(rg --version | head -1)"; \
	  echo "jq     : $$(jq --version)"'

sandbox: ## Example: run a command against THIS repo in the hardened sandbox
	./sandbox-run.sh . 'python3 --version && echo "hello from the sandbox"'

clean: ## Remove local run dirs
	rm -rf omnidev-runs

.DEFAULT_GOAL := help
