# First target in the Makefile is the default.
all: help

# without this 'source' won't work.
SHELL := /bin/bash

# Get the location of this makefile.
ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Specify the binary dependencies
REQUIRED_BINS := docker docker-compose
$(foreach bin,$(REQUIRED_BINS),\
    $(if $(shell command -v $(bin) 2> /dev/null),$(),$(error Please install `$(bin)` first!)))

.PHONY : help
help : Makefile
	@sed -n 's/^##//p' $<

## up                        : Start Node
.PHONY : up
up: ntpd-start
	@export COMPOSE_IGNORE_ORPHANS=true; docker-compose up -d

## down                      : Shutdown Node
.PHONY : down
down: ntpd-stop
	@export COMPOSE_IGNORE_ORPHANS=true; docker-compose down

## restart                   : Restart only chainpoint-node service
.PHONY : restart
restart:
	@export COMPOSE_IGNORE_ORPHANS=true; docker-compose restart chainpoint-node

## restart-all               : Restart all services
.PHONY : restart-all
restart-all: down up

## logs                      : Tail Node logs
.PHONY : logs
logs:
	@docker-compose logs -f -t | awk '/chainpoint-node/ && !(/DEBUG/ || /failed with exit code 99/ || /node server\.js/ || /yarnpkg\.com/)'

## logs-ntpd                 : Tail ntpd logs
.PHONY : logs-ntpd
logs-ntpd:
	@docker-compose -f docker-compose-ntpd.yaml logs -f -t | awk '/chainpoint-ntpd/'

## logs-redis                : Tail Redis logs
.PHONY : logs-redis
logs-redis:
	@docker-compose logs -f -t | awk '/redis/'

## logs-postgres             : Tail PostgreSQL logs
.PHONY : logs-postgres
logs-postgres:
	@docker-compose logs -f -t | awk '/postgres/'

## logs-all                  : Tail all logs
.PHONY : logs-all
logs-all:
	@docker-compose logs -f -t

## ps                        : View running processes
.PHONY : ps
ps:
	@docker-compose ps

## build-config              : Create new `.env` config file from `.env.sample`
.PHONY : build-config
build-config:
	@[ ! -f ./.env ] && \
	cp .env.sample .env && \
	echo 'Copied config .env.sample to .env' || true

## git-fetch                 : Git fetch latest
.PHONY : git-fetch
git-fetch:
	git fetch && git checkout master && git pull

## upgrade                   : Stop all, git pull, and start all
.PHONY : upgrade
upgrade: down git-fetch up

guard-ubuntu:
	@os=$$(lsb_release -si); \
	if [ "$${os}" != "Ubuntu" ]; then \
		echo "You do not appear to be running on a version of Ubuntu OS"; \
		exit 1; \
	fi

## upgrade-docker-compose    : Upgrade local docker-compose installation
.PHONY : upgrade-docker-compose
upgrade-docker-compose: guard-ubuntu
	@sudo mkdir -p /usr/local/bin; \
	sudo curl -s -L "https://github.com/docker/compose/releases/download/1.21.0/docker-compose-Linux-x86_64" -o /usr/local/bin/docker-compose; \
	sudo chmod +x /usr/local/bin/docker-compose

## postgres                  : Connect to the local PostgreSQL with `psql`
.PHONY : postgres
postgres:
	@export COMPOSE_IGNORE_ORPHANS=true; docker-compose up -d postgres
	@sleep 6
	@docker exec -it postgres-node psql -U chainpoint

## redis                     : Connect to the local Redis with `redis-cli`
.PHONY : redis
redis:
	@export COMPOSE_IGNORE_ORPHANS=true; docker-compose up -d redis
	@sleep 2
	@docker exec -it redis-node redis-cli

## auth-keys                 : Export HMAC auth keys from PostgreSQL
.PHONY : auth-keys
auth-keys:
	@export COMPOSE_IGNORE_ORPHANS=true; docker-compose up -d postgres
	@sleep 6
	@docker exec -it postgres-node psql -U chainpoint -c 'SELECT * FROM hmackeys;'

## backup-auth-keys              : Backup all auth keys to the keys/backups dir
.PHONY : backup-auth-keys
backup-auth-keys:
	@docker exec -it chainpointnodesrc_chainpoint-node_1 node auth-keys-backup-script.js

## auth-key-delete           : Delete HMAC auth key with `NODE_TNT_ADDRESS` var. Example `make auth-key-delete NODE_TNT_ADDRESS=0xmyethaddress`
.PHONY : auth-key-delete
auth-key-delete: guard-NODE_TNT_ADDRESS up
	@sleep 6
	@docker exec -it postgres-node psql -U chainpoint -c "DELETE FROM hmackeys WHERE tnt_addr = LOWER('$(NODE_TNT_ADDRESS)')"
	make restart

## calendar-delete           : Delete all calendar data for this Node
.PHONY : calendar-delete
calendar-delete:
	@export COMPOSE_IGNORE_ORPHANS=true; docker-compose up -d postgres
	@sleep 6
	@docker exec -it postgres-node psql -U chainpoint -c "DELETE FROM calendar"
	make restart

guard-%:
	@ if [ "${${*}}" = "" ]; then \
		echo "Environment variable $* not set"; \
		exit 1; \
	fi

.PHONY : sign-chainpoint-security-txt
sign-chainpoint-security-txt:
	gpg --armor --output chainpoint-security.txt.sig --detach-sig chainpoint-security.txt

## ntpd-start                : Start docker ntpd
.PHONY : ntpd-start
ntpd-start:
	@status=$$(ps -ef | grep -v -E '(grep|ntpd-start)' | grep ntpd | wc -l); \
	if test $${status} -ge 1; then \
		echo "Local NTPD seems to be running. Skipping chainpoint-ntpd..."; \
	else \
		echo Local NTPD is not running. Starting chainpoint-ntpd...; \
		export COMPOSE_IGNORE_ORPHANS=true; docker-compose -f docker-compose-ntpd.yaml up -d; \
	fi

## ntpd-stop                 : Stop docker ntpd
.PHONY : ntpd-stop
ntpd-stop:
	-@export COMPOSE_IGNORE_ORPHANS=true; docker-compose -f docker-compose-ntpd.yaml down;

## ntpd-status               : Show docker ntpd status
.PHONY : ntpd-status
ntpd-status:
	@echo ''
	@docker exec -it chainpoint-ntpd ntpctl -s all

# private target. Upload the installer shell script to a common location.
.PHONE : upload-installer
upload-installer:
	gsutil cp scripts/setup.sh gs://chainpoint-node/setup.sh
	gsutil acl ch -u AllUsers:R gs://chainpoint-node/setup.sh
	gsutil setmeta -h "Cache-Control:private, max-age=0, no-transform" gs://chainpoint-node/setup.sh
