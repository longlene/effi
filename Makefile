CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=c11
LIBFFI_CFLAGS ?= $(shell pkg-config --cflags libffi 2>/dev/null || echo -I/usr/lib64/libffi/include)
LIBFFI_LIBS   ?= $(shell pkg-config --libs   libffi 2>/dev/null || echo -lffi)

all: priv/effi_port

priv/effi_port: c_src/effi_port.c
	mkdir -p priv
	$(CC) $(CFLAGS) $(LIBFFI_CFLAGS) -o $@ $< $(LIBFFI_LIBS) -ldl

clean:
	rm -f priv/effi_port

.PHONY: all clean
