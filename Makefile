CC = gcc
CFLAGS = -Wall -Wextra -g
LDFLAGS = -pthread

SRCDIR = src
BINDIR = src

TARGETS = $(BINDIR)/test_uffd $(BINDIR)/test_uffd_tcp $(BINDIR)/test_loop $(BINDIR)/lazy_handler

.PHONY: all test clean bench bench-quick bench-paper report docs pdf

all: $(TARGETS)

$(BINDIR)/test_uffd: $(SRCDIR)/test_uffd.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(BINDIR)/test_uffd_tcp: $(SRCDIR)/test_uffd_tcp.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(BINDIR)/test_loop: $(SRCDIR)/test_loop.c
	$(CC) $(CFLAGS) -o $@ $<

$(BINDIR)/lazy_handler: $(SRCDIR)/lazy_handler.c $(SRCDIR)/hashset.h
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

test: all
	@bash tests/run_tests.sh

bench: all
	sudo bash eval/bench.sh --output-dir eval/results

bench-quick: all
	sudo bash eval/bench.sh --workloads test_loop --iterations 2 --output-dir eval/results

# Final paper dataset: all workloads × lazy,lazy-prefetch,lazy-adaptive in one run.
# Use --append to add workloads incrementally without clobbering results.csv.
bench-paper: all
	sudo bash eval/bench.sh \
		--workloads test_loop,redis,pytorch \
		--modes full,lazy,lazy-prefetch,lazy-adaptive \
		--iterations 5 \
		--output-dir eval/results

report:
	python3 eval/report.py --input eval/results/results.csv --output eval/results/report.md

figures:
	python3 eval/figures.py --csv eval/results/results.csv --logs eval/results/logs --out eval/results/figures

docs: report figures

paper/paper.pdf: paper/paper.tex paper/references.bib
	cd paper && pdflatex -interaction=nonstopmode paper.tex && \
	bibtex paper && \
	pdflatex -interaction=nonstopmode paper.tex && \
	pdflatex -interaction=nonstopmode paper.tex

pdf: paper/paper.pdf
	@echo "Reports: eval/results/report.md"
	@echo "Evaluation: docs/evaluation.md"

clean:
	rm -f $(TARGETS)
