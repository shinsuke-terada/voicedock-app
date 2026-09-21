# VoiceDock の Makefile（PLAN §3.2）。CI と手元で同じコマンドを使う。
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := test

SWIFT ?= swift
FORMAT_PATHS := Sources Tests

# $(1) のスクリプトが無ければ、作るチケット $(2) を示して止める
define require_script
	@test -x "$(1)" || { echo "ERROR: $(1) がありません（$(2) で作る）" >&2; exit 1; }
endef

.PHONY: check-toolchain lint fmt build test test-nd test-policy test-other test-disk \
        vendor app golden llm-acceptance release clean

# .xcode-version と使っている Xcode が一致することを確かめる（CI と手元で同じコンパイラを使う。PLAN §3.3）
check-toolchain:
	@want="Xcode $$(cat .xcode-version)"; have="$$(xcodebuild -version | head -n 1)"; \
	  if [ "$$want" != "$$have" ]; then \
	    echo "ERROR: $$have を使っています。$$want に切り替えてください（sudo xcode-select -s <Xcode のパス>）" >&2; exit 1; \
	  fi

# swift format は存在しないパスを渡しても 0 で終わるので、先に確かめる（PLAN §3.3）
lint:
	@for d in $(FORMAT_PATHS); do test -d "$$d" || { echo "ERROR: $$d がありません" >&2; exit 1; }; done
	$(SWIFT) format lint --strict --recursive $(FORMAT_PATHS)

fmt:
	@for d in $(FORMAT_PATHS); do test -d "$$d" || { echo "ERROR: $$d がありません" >&2; exit 1; }; done
	$(SWIFT) format --in-place --recursive $(FORMAT_PATHS)

build: check-toolchain
	$(SWIFT) build --build-tests

# CI の check と同じ順（ND → policy → 残り。PLAN §10.8）
test: build
	$(SWIFT) test --skip-build --filter "NoDeleteTests|ReaperTests"
	$(SWIFT) test --skip-build --filter PolicyTests
	$(SWIFT) test --skip-build --skip "NoDeleteTests|ReaperTests|PolicyTests|LLMAcceptance"

test-nd: build
	$(SWIFT) test --skip-build --filter "NoDeleteTests|ReaperTests"

test-policy: build
	$(SWIFT) test --skip-build --filter PolicyTests

test-other: build
	$(SWIFT) test --skip-build --skip "NoDeleteTests|ReaperTests|PolicyTests|LLMAcceptance"

# ディスクイメージのテストを含めて全部（swift test はタグで絞れないので環境変数で有効化する。PLAN §10.1）
test-disk:
	VOICEDOCK_DISK_TESTS=1 $(MAKE) test

vendor:
	$(call require_script,Vendor/build-whisper.sh,T-03)
	$(call require_script,Vendor/build-llama.sh,T-03)
	Vendor/build-whisper.sh
	Vendor/build-llama.sh

app:
	$(call require_script,scripts/make-app.sh,T-34)
	scripts/make-app.sh debug

golden:
	$(call require_script,tools/golden/generate.sh,T-25)
	tools/golden/generate.sh

llm-acceptance: build
	@test -n "$(MODEL)" || { echo "ERROR: MODEL=<モデルの ID> を指定してください" >&2; exit 1; }
	VOICEDOCK_LLM_MODEL="$(MODEL)" $(SWIFT) test --skip-build --filter LLMAcceptance

release:
	$(call require_script,scripts/release.sh,T-34)
	scripts/release.sh

clean:
	rm -rf .build dist
