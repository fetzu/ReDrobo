# droboprobe -- kext-free Drobo management probe
#
# Builds a universal binary so the same tool runs on the 2017 iMac (x86_64)
# and on Apple Silicon.

BIN      := droboprobe
SRC      := droboprobe.c
ARCHS    := -arch arm64 -arch x86_64
CFLAGS   := -Wall -Wextra -O2 -mmacosx-version-min=11.0
LDFLAGS  := -framework CoreFoundation -framework IOKit

.PHONY: all clean native

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(ARCHS) $(CFLAGS) -o $@ $< $(LDFLAGS)

# Single-arch build, useful when cross-SDK bits are missing.
native: $(SRC)
	$(CC) $(CFLAGS) -o $(BIN) $< $(LDFLAGS)

clean:
	rm -f $(BIN)
