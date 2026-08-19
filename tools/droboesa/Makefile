# droboesa -- dump Drobo ESA records through Drobo's own kext (read-only).
#
# Universal so the same binary runs on the old Intel Mac that still has
# Dashboard installed and on Apple Silicon.

BIN      := droboesa
SRC      := droboesa.c
ARCHS    := -arch arm64 -arch x86_64
CFLAGS   := -Wall -Wextra -O2 -mmacosx-version-min=11.0
LDFLAGS  := -framework CoreFoundation -framework IOKit

.PHONY: all clean native

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(ARCHS) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Single-arch fallback if the cross SDK bits are missing.
native: $(SRC)
	$(CC) $(CFLAGS) -o $(BIN) $< $(LDFLAGS)

clean:
	rm -f $(BIN)
