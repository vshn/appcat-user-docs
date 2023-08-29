pages   := $(shell find . -type f -name '*.adoc')
web_dir := ./_public

# Determine whether to use podman
#
# podman currently fails when executing in GitHub actions on Ubuntu LTS 20.04,
# so we never use podman if GITHUB_ACTIONS==true.
use_podman := $(shell command -v podman 2>&1 >/dev/null; p="$$?"; \
		if [ "$${GITHUB_ACTIONS}" != "true" ]; then echo "$$p"; else echo 1; fi)

ifeq ($(use_podman),0)
	engine_cmd  ?= podman
	engine_opts ?= --rm --tty --userns=keep-id
else
	engine_cmd  ?= docker
	engine_opts ?= --rm --tty --user "$$(id -u)"
endif

orphans_cmd ?= $(engine_cmd) run $(engine_opts) --volume "$${PWD}:/antora" ghcr.io/vshn/antora-nav-orphans-checker:1.1 -antoraPath /antora/docs
vale_cmd ?= $(engine_cmd) run $(engine_opts) --volume "$${PWD}"/docs/modules/ROOT/pages:/pages --workdir /pages ghcr.io/vshn/vale:2.15.5 --minAlertLevel=error .
preview_cmd ?= $(engine_cmd) run --rm --publish 35729:35729 --publish 2020:2020 --volume "${PWD}":/preview/antora ghcr.io/vshn/antora-preview:3.1.4 --antora=docs --style=vshn
antora_cmd  ?= $(engine_cmd) run $(engine_opts) --volume "$${PWD}":/antora ghcr.io/vshn/antora:3.1.2.2
antora_opts ?= --cache-dir=.cache/antora

.PHONY: all
all: preview

.PHONY: check
check:
	$(orphans_cmd)
	$(vale_cmd)

.PHONY: preview
preview:
	$(preview_cmd)

.PHONY: html
html:    $(web_dir)/index.html

$(web_dir)/index.html: playbook.yml $(pages)
	$(antora_cmd) $(antora_opts) $<


## CRD API doc generator

go_bin ?= $(PWD)/.work/bin
$(go_bin):
	@mkdir -p $@

crd_ref_docs_bin ?= $(go_bin)/crd-ref-docs

$(crd_ref_docs_bin): export GOBIN = $(go_bin)
$(crd_ref_docs_bin): | $(go_bin)
	go install github.com/elastic/crd-ref-docs@latest

crd_branch ?= master


clone-crds:
	rm -rf .work/crds
	git clone https://github.com/vshn/appcat/ .work/crds
	cd .work/crds && git checkout $(crd_branch)

.PHONY: docs-generate-api
docs-generate-api: $(crd_ref_docs_bin) ## Generates API reference documentation
docs-generate-api: clone-crds
	$(crd_ref_docs_bin) --source-path=.work/crds/apis/v1 --config=generator/api-gen-config.yaml --renderer=asciidoctor --templates-dir=generator/api-templates --output-path=docs/modules/ROOT/pages/references/crds.adoc
	$(crd_ref_docs_bin) --source-path=.work/crds/apis/exoscale/v1 --config=generator/api-gen-config.yaml --renderer=asciidoctor --templates-dir=generator/api-templates --output-path=docs/modules/ROOT/pages/references/crds_exo.adoc
	$(crd_ref_docs_bin) --source-path=.work/crds/apis/vshn/v1 --config=generator/api-gen-config.yaml --renderer=asciidoctor --templates-dir=generator/api-templates --output-path=docs/modules/ROOT/pages/references/crds_vshn.adoc
	# a bit hacky, but the tool doesn't support multiple api groups with one call...
	cat docs/modules/ROOT/pages/references/crds_exo.adoc | sed "s/= API Reference/== Exoscale Reference/g" >> docs/modules/ROOT/pages/references/crds.adoc
	cat docs/modules/ROOT/pages/references/crds_vshn.adoc | sed "s/= API Reference/== VSHN Reference/g" >> docs/modules/ROOT/pages/references/crds.adoc
	rm docs/modules/ROOT/pages/references/crds_*.adoc
	go run main.go