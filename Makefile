.PHONY: install test lint demo

install:
	python -m pip install -e '.[dev]'

test:
	pytest -q

lint:
	ruff check .

demo:
	bash scripts/demo_m0.sh
