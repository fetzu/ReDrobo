# DroboDext -- skeleton DriverKit driver for Drobo DAS enclosures.
#
# This replaces TrustedDataSCSIDriver.kext with a userspace driver extension.
# It builds and links today against the DriverKit SDK in Xcode 26; it will not
# *load* until the SCSI-peripheral family entitlement is in place (see
# DroboDext.entitlements).
#
#   make            build DroboDext.dext (universal)
#   make sign       ad-hoc sign (enough to inspect; NOT enough to load)
#   make clean

MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

# sysextd finds an embedded extension by <identifier>.dext, so the bundle
# directory and the executable inside it are both named after the bundle id.
# A short name here is exactly what produced 'Extension not found in App
# bundle' for four rounds.
DEXT      := DroboDext
DEXT_ID   := org.redrobo.ReDrobo.DroboDext
BUNDLE    := $(DEXT_ID).dext
DKPLAT    := /Applications/Xcode.app/Contents/Developer/Platforms/DriverKit.platform
SDK       := $(DKPLAT)/Developer/SDKs/DriverKit.sdk
DKVER     := 25.5
FRAMEWORKS := $(SDK)/System/DriverKit/System/Library/Frameworks

# The build number lives in Info.plist and nowhere else. It reaches the code as
# a -D and the matched service as a DroboBuild property, so "which build is
# actually running" has one answer in all three places. It used to be a #define
# in the .cpp, which drifted from the plist the first time make bump ran and
# quietly made the log line untrustworthy.
BUILD     := $(shell plutil -extract CFBundleVersion raw -o - Info.plist)

CXXFLAGS  := -std=gnu++2b -fno-exceptions -fno-rtti -Wall -Wextra -O2 \
             -DDROBO_DEXT_BUILD='"$(BUILD)"'
INCLUDES  := -isysroot $(SDK) -F$(FRAMEWORKS)
LDLIBS    := -framework DriverKit -framework SCSIPeripheralsDriverKit
IIGCLASSES := DroboDext DroboUserClient
GENERATED  := $(addsuffix .h,$(IIGCLASSES)) $(addsuffix .iig.cpp,$(IIGCLASSES))
SOURCES   := $(DEXT).cpp $(addsuffix .iig.cpp,$(IIGCLASSES))
# Apple Silicon dexts must be arm64e, not plain arm64. Every dext in
# /System/Library/DriverExtensions is x86_64 + arm64e. A plain arm64 slice
# gets picked by sysextd and then the kernel refuses to exec it:
#   kernelmanagerd: Error launching dext ... Code=8 "Exec format error"
ARCHS     := arm64e x86_64

.PHONY: all clean sign iig

all: $(BUNDLE)

# Step 1: iig turns each .iig class definition into a header + RPC glue.
# One class per .iig file, because the generated code includes <Class>.h.
%.h %.iig.cpp: %.iig
	xcrun iig --def $< --header $*.h --impl $*.iig.cpp -- \
		-x c++ -std=gnu++2b -D__IIG=1 $(INCLUDES) \
		-I$(SDK)/System/DriverKit/usr/include \
		-I$(SDK)/System/DriverKit/usr/local/include

# Step 2: compile + link one slice per architecture, then lipo them together.
build/$(DEXT)-%: $(SOURCES) $(GENERATED) Info.plist
	@mkdir -p build
	xcrun clang++ -target $*-apple-driverkit$(DKVER) $(INCLUDES) $(CXXFLAGS) \
		-L$(SDK)/System/DriverKit/usr/lib $(LDLIBS) -o $@ $(SOURCES)

# NOTE: a .dext is a FLAT bundle, not a macOS Contents/ bundle. Every dext
# shipped in /System/Library/DriverExtensions is laid out this way, and sysextd
# will not see one that uses Contents/. Getting this wrong shows up as the very
# misleading "Extension not found in App bundle".
$(BUNDLE): $(addprefix build/$(DEXT)-,$(ARCHS)) Info.plist
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)
	python3 -c "import plistlib; \
	  d = plistlib.load(open('Info.plist','rb')); \
	  [p.update({'DroboBuild': d['CFBundleVersion']}) \
	   for p in d['IOKitPersonalities'].values()]; \
	  plistlib.dump(d, open('$(BUNDLE)/Info.plist','wb'), sort_keys=False)"
	lipo -create $(addprefix build/$(DEXT)-,$(ARCHS)) -output $(BUNDLE)/$(DEXT_ID)
	@echo "built $(BUNDLE): $$(lipo -archs $(BUNDLE)/$(DEXT_ID)), build $(BUILD)"

sign: $(BUNDLE)
	codesign --force --sign - --entitlements $(DEXT).entitlements $(BUNDLE)
	codesign -dvvv --entitlements - $(BUNDLE)

clean:
	rm -rf $(BUNDLE) build $(GENERATED) *.o
