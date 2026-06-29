IMAGE ?= local/arti-socks-proxy:latest
CONTAINER ?= arti-socks-proxy
TEST_CONTAINER ?= arti-socks-proxy-test
PLATFORM ?= linux/amd64

HEALTHCHECK_URL ?= https://check.torproject.org/api/ip
HEALTHCHECK_EXPECTED ?= "IsTor":true
HEALTHCHECK_MAX_TIME ?= 30
TEST_RETRIES ?= 24
TEST_SLEEP ?= 5
CURL_TEST_URL ?= https://check.torproject.org/api/ip

.PHONY: help build run stop restart logs health curl-test test compose-up compose-down clean

help:
	@printf '%s\n' 'Targets:'
	@printf '%s\n' '  make build        Build $(IMAGE)'
	@printf '%s\n' '  make run          Run $(CONTAINER)'
	@printf '%s\n' '  make stop         Stop and remove $(CONTAINER)'
	@printf '%s\n' '  make restart      Recreate $(CONTAINER)'
	@printf '%s\n' '  make logs         Tail container logs'
	@printf '%s\n' '  make health       Show Docker health status'
	@printf '%s\n' '  make curl-test    Test the host SOCKS port with curl'
	@printf '%s\n' '  make test         Build and verify healthcheck in a disposable container'
	@printf '%s\n' '  make compose-up   Build and start with Docker Compose'
	@printf '%s\n' '  make compose-down Stop Docker Compose service'
	@printf '%s\n' '  make clean        Remove local image'
	@printf '\n'
	@printf '%s\n' 'Overrides:'
	@printf '%s\n' '  IMAGE=$(IMAGE)'
	@printf '%s\n' '  PLATFORM=$(PLATFORM)'
	@printf '%s\n' '  HEALTHCHECK_URL=$(HEALTHCHECK_URL)'
	@printf '%s\n' '  HEALTHCHECK_EXPECTED=$(HEALTHCHECK_EXPECTED)'

build:
	docker build --platform $(PLATFORM) -t $(IMAGE) .

run: build
	docker rm -f $(CONTAINER) >/dev/null 2>&1 || true
	docker run -d \
		--platform $(PLATFORM) \
		--restart=always \
		--name $(CONTAINER) \
		--log-driver=local \
		--log-opt max-size=10m \
		--log-opt max-file=3 \
		-e HEALTHCHECK_URL='$(HEALTHCHECK_URL)' \
		-e HEALTHCHECK_EXPECTED='$(HEALTHCHECK_EXPECTED)' \
		-e HEALTHCHECK_MAX_TIME='$(HEALTHCHECK_MAX_TIME)' \
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
	curl --fail --silent --show-error --max-time $(HEALTHCHECK_MAX_TIME) \
		--socks5-hostname 127.0.0.1:9150 \
		$(CURL_TEST_URL)

test: build
	@set -eu; \
	docker rm -f $(TEST_CONTAINER) >/dev/null 2>&1 || true; \
	docker run -d \
		--platform $(PLATFORM) \
		--name $(TEST_CONTAINER) \
		-e HEALTHCHECK_URL='$(HEALTHCHECK_URL)' \
		-e HEALTHCHECK_EXPECTED='$(HEALTHCHECK_EXPECTED)' \
		-e HEALTHCHECK_MAX_TIME='$(HEALTHCHECK_MAX_TIME)' \
		$(IMAGE) >/dev/null; \
	trap 'status=$$?; if [ $$status -ne 0 ]; then docker logs --tail=100 $(TEST_CONTAINER) || true; fi; docker rm -f $(TEST_CONTAINER) >/dev/null 2>&1 || true; exit $$status' EXIT; \
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

compose-up:
	docker compose up -d --build

compose-down:
	docker compose down

clean:
	docker image rm $(IMAGE) >/dev/null 2>&1 || true
