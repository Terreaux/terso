# Terso — common tasks. `make help` lists them.
SHELL := /bin/sh
.DEFAULT_GOAL := help

CONFIG   ?= release
APP      := build/Terso.app
DOC      ?= Samples/essay.md
BIN       = $(shell swift build -c $(CONFIG) --show-bin-path)
EVAL      = $(BIN)/terso-eval
CORPORA  := Evaluation/Corpora
LABEL    ?= run
AI_LIMIT ?= 40
JOBS     ?= 4



.PHONY: corpus-academic corpus-technical icon help build app dmg run test test-live test-live-codex eval-build corpus ai-corpus ai-corpus-codex evaluate compare clean

help: ## Show this help
	@awk 'BEGIN{FS=":.*## "} /^[a-z%-]+:.*## /{printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo "\n  Variables: CONFIG=$(CONFIG) DOC=$(DOC) LABEL=… AI_LIMIT=$(AI_LIMIT) JOBS=$(JOBS) BEFORE=… AFTER=…"

build: ## Compile all targets
	swift build -c $(CONFIG)

app: ## Build build/Terso.app
	scripts/bundle.sh $(CONFIG)

dmg: ## Build and verify a DMG for the current Mac architecture
	sh scripts/dmg.sh $(CONFIG)

run: app ## Build the app and open DOC in it
	-pkill -f "$(APP)/Contents/MacOS/Terso"
	open -a "$(CURDIR)/$(APP)" "$(CURDIR)/$(DOC)"

test: ## Run the unit tests
	swift test

test-live: ## Live test against Apple's on-device model (free, local)
	TERSO_LIVE_APPLE=1 swift test --filter LiveAppleTests

test-live-codex: ## Live Codex CLI round-trip (spends your Codex tokens)
	TERSO_LIVE_CODEX=1 swift test --filter codexRoundTrip

eval-build:
	swift build -c $(CONFIG) --product terso-eval

corpus: ## Fetch the human evaluation corpus from dev.to, split by author (not committed)
	python3 scripts/fetch-corpus.py $(CORPORA)/Human

ai-corpus: ## Generate AI counterparts of held-out titles with Apple's on-device model (free, local)
	swift build -c $(CONFIG) --product terso-fm
	TERSO_AI_CMD="$(BIN)/terso-fm" TERSO_AI_TAG=apple scripts/generate-ai-corpus.sh heldout $(AI_LIMIT) 1

ai-corpus-codex: ## Same, with Codex CLI (spends your Codex tokens)
	scripts/generate-ai-corpus.sh heldout $(AI_LIMIT) $(JOBS)

evaluate: eval-build ## Evaluate the shipped bands on the held-out corpora → Evaluation/Reports/$(LABEL).json
	$(EVAL) evaluate --human $(CORPORA)/Human/heldout --ai $(CORPORA)/AI/heldout \
	  --label $(LABEL) --out Evaluation/Reports/$(LABEL).json

compare: eval-build ## Regression report: make compare BEFORE=a.json AFTER=b.json
	@test -n "$(BEFORE)" -a -n "$(AFTER)" || { echo "usage: make compare BEFORE=… AFTER=…"; exit 2; }
	$(EVAL) compare $(BEFORE) $(AFTER)

# --- Terso's own register measurements (academic, technical) -------------
SRC      ?= $(HOME)/.cache/terso/docs
FM        = $(BIN)/terso-fm
PROMPT_academic  := Write the introduction section of a research article titled "{title}". Around {words} words. Reply with the introduction as plain paragraphs only: no title, no headings, no reference list.
PROMPT_technical := Write a documentation page titled "{title}" for an open-source software project. Around {words} words. Reply with the page in Markdown only.
CORPUS_academic  := Academic
CORPUS_technical := Technical

corpus-academic: ## Fetch academic introductions (Europe PMC, CC BY, 2016–2021), split by journal
	python3 scripts/fetch-academic.py $(CORPORA)/Academic --target 240

corpus-technical: ## Build the technical corpus from pinned pre-2022 docs (Kubernetes, Django, CPython)
	mkdir -p $(SRC)
	[ -d $(SRC)/django ] || git clone -q --depth 1 --branch 3.2.10 --filter=blob:none --sparse https://github.com/django/django $(SRC)/django && git -C $(SRC)/django sparse-checkout set docs
	[ -d $(SRC)/cpython ] || git clone -q --depth 1 --branch v3.9.9 --filter=blob:none --sparse https://github.com/python/cpython $(SRC)/cpython && git -C $(SRC)/cpython sparse-checkout set Doc
	[ -d $(SRC)/k8s ] || { git clone -q --shallow-since=2021-06-01 --branch release-1.22 --filter=blob:none --no-checkout https://github.com/kubernetes/website $(SRC)/k8s && git -C $(SRC)/k8s sparse-checkout set content/en/docs && git -C $(SRC)/k8s checkout -q $$(git -C $(SRC)/k8s rev-list -n1 --before=2022-01-01 HEAD); }
	python3 scripts/build-technical.py $(SRC) $(CORPORA)/Technical --per-section 6

ai-corpus-%: ## AI counterparts for a register (academic|technical), on-device and free
	swift build -c $(CONFIG) --product terso-fm
	TERSO_HUMAN="$(CURDIR)/$(CORPORA)/$(CORPUS_$*)" TERSO_AI_OUT="$(CURDIR)/$(CORPORA)/$(CORPUS_$*)-AI" TERSO_AI_CMD="$(FM)" \
	  TERSO_AI_TAG=apple TERSO_PROMPT='$(PROMPT_$*)' scripts/generate-ai-corpus.sh calibration 50 1
	TERSO_HUMAN="$(CURDIR)/$(CORPORA)/$(CORPUS_$*)" TERSO_AI_OUT="$(CURDIR)/$(CORPORA)/$(CORPUS_$*)-AI" TERSO_AI_CMD="$(FM)" \
	  TERSO_AI_TAG=apple TERSO_PROMPT='$(PROMPT_$*)' scripts/generate-ai-corpus.sh heldout 40 1

calibrate-%: eval-build ## Measure a register's bands on its calibration split → Sources/TersoStyle/Resources/bands-<register>.json
	$(EVAL) calibrate --human $(CORPORA)/$(CORPUS_$*)/calibration --ai $(CORPORA)/$(CORPUS_$*)-AI/calibration \
	  --out Sources/TersoStyle/Resources/bands-$*.json --source "$$(cat Evaluation/Baselines/$*.source)"

evaluate-%: eval-build ## Evaluate a register's bands on its held-out split
	$(EVAL) evaluate --bands Sources/TersoStyle/Resources/bands-$*.json --human $(CORPORA)/$(CORPUS_$*)/heldout \
	  --ai $(CORPORA)/$(CORPUS_$*)-AI/heldout --label $*-heldout --out Evaluation/Reports/$*-heldout.json

icon: ## Regenerate Support/AppIcon.icns
	swift scripts/make-icon.swift Support

clean: ## Remove build products
	swift package clean
	rm -rf build
