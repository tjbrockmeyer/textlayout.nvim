.PHONY: test demo demo-inline lint

NVIM ?= nvim

test:
	$(NVIM) --headless -l tests/run.lua

demo:
	$(NVIM) -c 'edit examples/character-sheet.tl' -c 'TextLayout open'

demo-inline:
	$(NVIM) -c 'edit examples/character-sheet.tlmd'
