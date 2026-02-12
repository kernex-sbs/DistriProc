CC = gcc
CFLAGS = -Wall -Wextra -g
LDFLAGS = -pthread

SRCDIR = src
BINDIR = src

TARGETS = $(BINDIR)/test_uffd $(BINDIR)/test_uffd_tcp $(BINDIR)/test_loop $(BINDIR)/lazy_handler

.PHONY: all test clean

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

clean:
	rm -f $(TARGETS)
