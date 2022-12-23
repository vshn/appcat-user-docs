docker_cmd  ?= docker
docker_opts ?= --rm --tty --user "$$(id -u)"

vale_cmd ?= $(docker_cmd) run $(docker_opts) --volume "$${PWD}"/docs/modules/ROOT/pages:/pages docker.io/vshn/vale:2.10.5.1 --minAlertLevel=error /pages
preview_cmd ?= $(docker_cmd) run --rm --publish 35729:35729 --publish 2020:2020 --volume "${PWD}":/preview/antora docker.io/vshn/antora-preview:3.1.1.1 --antora=docs --style=appuio

.PHONY: all
all: preview

.PHONY: check
check:
	$(vale_cmd)

.PHONY: preview
preview:
	$(preview_cmd)

## CRD API doc generator

go_bin ?= $(PWD)/.work/bin
$(go_bin):
	@mkdir -p $@

crd_ref_docs_bin ?= $(go_bin)/crd-ref-docs

$(crd_ref_docs_bin): export GOBIN = $(go_bin)
$(crd_ref_docs_bin): | $(go_bin)
	go install github.com/elastic/crd-ref-docs@latest

clone-crds:
	rm -rf .work/crds
	git clone --depth 1 https://github.com/vshn/component-appcat/ .work/crds

.PHONY: docs-generate-api
docs-generate-api: $(crd_ref_docs_bin) ## Generates API reference documentation
docs-generate-api: clone-crds
	$(crd_ref_docs_bin) --source-path=.work/crds/apis/v1 --config=generator/api-gen-config.yaml --renderer=asciidoctor --templates-dir=generator/api-templates --output-path=docs/modules/ROOT/pages/references/crds.adoc
