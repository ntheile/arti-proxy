IMAGE ?= ghcr.io/ntheile/arti-proxy:latest
CONTAINER ?= arti-socks-proxy
TEST_CONTAINER ?= arti-socks-proxy-test
PLATFORM ?= linux/amd64

HEALTHCHECK_URL ?= https://check.torproject.org/api/ip
HEALTHCHECK_EXPECTED ?= "IsTor":true
HEALTHCHECK_MAX_TIME ?= 30
TEST_RETRIES ?= 24
TEST_SLEEP ?= 5
CURL_TEST_URL ?= https://check.torproject.org/api/ip
CURL_TEST_HOST ?= 127.0.0.1
CURL_TEST_PORT ?= 9150
CURL_TEST_VERBOSE ?= 0

export SOCKS_USERNAME
export SOCKS_PASSWORD

.PHONY: help build run run-with-dns stop restart logs health curl-test test compose-up compose-up-with-dns compose-down clean

help:
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  make build        Build $(IMAGE)'
	@printf '%s\n' '  make run          Run $(CONTAINER)'
	@printf '%s\n' '  make run-with-dns Run $(CONTAINER) with public SOCKS and public DNS'
	@printf '%s\n' '  make stop         Stop and remove $(CONTAINER)'
	@printf '%s\n' '  make restart      Recreate $(CONTAINER)'
	@printf '%s\n' '  make logs         Tail container logs'
	@printf '%s\n' '  make health       Show Docker health status'
	@printf '%s\n' '  make curl-test    Test the host SOCKS port with curl'
	@printf '%s\n' '  make test         Build and verify healthcheck in a disposable container'
	@printf '%s\n' '  make compose-up   Build and start with Docker Compose'
	@printf '%s\n' '  make compose-up-with-dns Build and start Compose with public DNS'
	@printf '%s\n' '  make compose-down Stop Docker Compose service'
	@printf '%s\n' '  make clean        Remove image'
	@printf '\n'
	@printf '%s\n' 'Overrides:'
	@printf '%s\n' '  IMAGE=$(IMAGE)'
	@printf '%s\n' '  PLATFORM=$(PLATFORM)'
	@printf '%s\n' '  SOCKS_USERNAME=$(SOCKS_USERNAME)'
	@printf '%s\n' '  SOCKS_PASSWORD=<hidden>'
	@printf '%s\n' '  HEALTHCHECK_URL=$(HEALTHCHECK_URL)'
	@printf '%s\n' '  HEALTHCHECK_EXPECTED=$(HEALTHCHECK_EXPECTED)'
	@printf '%s\n' '  CURL_TEST_HOST=$(CURL_TEST_HOST)'
	@printf '%s\n' '  CURL_TEST_PORT=$(CURL_TEST_PORT)'

require-socks-credentials:
	@if [ -z "$$SOCKS_USERNAME" ]; then \
		printf '%s\n' 'SOCKS_USERNAME is required. Example: make run SOCKS_USERNAME=arti SOCKS_PASSWORD=use-a-long-random-password' >&2; \
		exit 1; \
	fi
	@if [ -z "$$SOCKS_PASSWORD" ]; then \
		printf '%s\n' 'SOCKS_PASSWORD is required. Example: make run SOCKS_USERNAME=arti SOCKS_PASSWORD=use-a-long-random-password' >&2; \
		exit 1; \
	fi

build:
	docker build --platform $(PLATFORM) -t $(IMAGE) .

run: require-socks-credentials build
	docker rm -f $(CONTAINER) >/dev/null 2>&1 || true
	@env_file=$$(mktemp); \
	trap 'rm -f "$$env_file"' EXIT; \
	{ \
		printf '%s\n' 'HEALTHCHECK_URL=$(HEALTHCHECK_URL)'; \
		printf '%s\n' 'HEALTHCHECK_EXPECTED=$(HEALTHCHECK_EXPECTED)'; \
		printf '%s\n' 'HEALTHCHECK_MAX_TIME=$(HEALTHCHECK_MAX_TIME)'; \
		printf '%s\n' "SOCKS_USERNAME=$$SOCKS_USERNAME"; \
		printf '%s\n' "SOCKS_PASSWORD=$$SOCKS_PASSWORD"; \
	} > "$$env_file"; \
	docker run -d \
		--platform $(PLATFORM) \
		--restart=always \
		--name $(CONTAINER) \
		--log-driver=local \
		--log-opt max-size=10m \
		--log-opt max-file=3 \
		--env-file "$$env_file" \
		-p 0.0.0.0:9150:9150/tcp \
		$(IMAGE)

run-with-dns: require-socks-credentials build
	docker rm -f $(CONTAINER) >/dev/null 2>&1 || true
	@env_file=$$(mktemp); \
	trap 'rm -f "$$env_file"' EXIT; \
	{ \
		printf '%s\n' 'HEALTHCHECK_URL=$(HEALTHCHECK_URL)'; \
		printf '%s\n' 'HEALTHCHECK_EXPECTED=$(HEALTHCHECK_EXPECTED)'; \
		printf '%s\n' 'HEALTHCHECK_MAX_TIME=$(HEALTHCHECK_MAX_TIME)'; \
		printf '%s\n' "SOCKS_USERNAME=$$SOCKS_USERNAME"; \
		printf '%s\n' "SOCKS_PASSWORD=$$SOCKS_PASSWORD"; \
		printf '%s\n' "DNS_LISTEN=0.0.0.0:8853"; \
	} > "$$env_file"; \
	docker run -d \
		--platform $(PLATFORM) \
		--restart=always \
		--name $(CONTAINER) \
		--log-driver=local \
		--log-opt max-size=10m \
		--log-opt max-file=3 \
		--env-file "$$env_file" \
		-p 0.0.0.0:9150:9150/tcp \
		-p 0.0.0.0:5353:8853/udp \
		$(IMAGE)

stop:
	docker rm -f $(CONTAINER) >/dev/null 2>&1 || true

restart: stop run

logs:
	docker logs -f --tail=100 $(CONTAINER)

health:
	docker inspect $(CONTAINER) --format '{{json .State.Health}}'

curl-test:
	@if [ -z "$$SOCKS_USERNAME" ]; then \
		printf '%s\n' 'SOCKS_USERNAME is required. Example: make curl-test SOCKS_USERNAME=arti SOCKS_PASSWORD=use-a-long-random-password' >&2; \
		exit 1; \
	fi
	@if [ -z "$$SOCKS_PASSWORD" ]; then \
		printf '%s\n' 'SOCKS_PASSWORD is required. Example: make curl-test SOCKS_USERNAME=arti SOCKS_PASSWORD=use-a-long-random-password' >&2; \
		exit 1; \
	fi
	@set -eu; \
	curl_flags='--fail --silent --show-error'; \
	if [ "$(CURL_TEST_VERBOSE)" = "1" ]; then \
		curl_flags='--fail --show-error --verbose'; \
	fi; \
	curl $$curl_flags --max-time $(HEALTHCHECK_MAX_TIME) \
		--proxy-user "$$SOCKS_USERNAME:$$SOCKS_PASSWORD" \
		--socks5-hostname "$(CURL_TEST_HOST):$(CURL_TEST_PORT)" \
		"$(CURL_TEST_URL)"

test: require-socks-credentials build
	@set -eu; \
	env_file=$$(mktemp); \
	{ \
		printf '%s\n' 'HEALTHCHECK_URL=$(HEALTHCHECK_URL)'; \
		printf '%s\n' 'HEALTHCHECK_EXPECTED=$(HEALTHCHECK_EXPECTED)'; \
		printf '%s\n' 'HEALTHCHECK_MAX_TIME=$(HEALTHCHECK_MAX_TIME)'; \
		printf '%s\n' "SOCKS_USERNAME=$$SOCKS_USERNAME"; \
		printf '%s\n' "SOCKS_PASSWORD=$$SOCKS_PASSWORD"; \
	} > "$$env_file"; \
	docker rm -f $(TEST_CONTAINER) >/dev/null 2>&1 || true; \
	docker run -d \
		--platform $(PLATFORM) \
		--name $(TEST_CONTAINER) \
		--env-file "$$env_file" \
		$(IMAGE) >/dev/null; \
	trap 'status=$$?; rm -f "$$env_file"; if [ $$status -ne 0 ]; then docker logs --tail=100 $(TEST_CONTAINER) || true; fi; docker rm -f $(TEST_CONTAINER) >/dev/null 2>&1 || true; exit $$status' EXIT; \
	for attempt in $$(seq 1 $(TEST_RETRIES)); do \
		if docker exec $(TEST_CONTAINER) /usr/local/bin/arti-healthcheck.sh >/dev/null 2>&1; then \
			echo "Healthcheck passed on attempt $$attempt"; \
			docker inspect $(TEST_CONTAINER) --format '{{json .State.Health}}'; \
			exit 0; \
		fi; \
		echo "Waiting for Arti bootstrap ($$attempt/$(TEST_RETRIES))"; \
		sleep $(TEST_SLEEP); \
	done; \
	echo "Healthcheck failed after $(TEST_RETRIES) attempts"; \
	exit 1

compose-up: require-socks-credentials
	docker compose up -d --build

compose-up-with-dns: require-socks-credentials
	docker compose -f docker-compose.yml -f docker-compose.dns.yml up -d --build

compose-down:
	docker compose -f docker-compose.yml -f docker-compose.dns.yml down

clean:
	docker image rm $(IMAGE) >/dev/null 2>&1 || true
