# ReDrobo.app -- host app that carries and activates DroboDext.
#
# A driver extension cannot be installed on its own. It has to sit inside an
# app bundle, in /Applications, and be activated by that app. So this builds
# the app, embeds the dext, and signs both.
#
#   make            build and sign ReDrobo.app
#   make install    copy it to /Applications (required, the system insists)
#   make check      show what got signed and with which entitlements
#   make clean
#
#   make RELEASE=1 notarize    Developer ID build, notarized and stapled
#
# Signing: your Apple Development identity and the two development provisioning
# profiles by default. RELEASE=1 switches to Developer ID, the two Developer ID
# profiles and a secure timestamp. The development capabilities are self-serve
# and the distribution ones have to be granted by Apple, which is the whole
# difference between the two paths; docs/DRIVERKIT.md has the detail.

MAKEFLAGS += --no-builtin-rules
.SUFFIXES:

APP        := ReDrobo
BUNDLE     := $(APP).app
DEXT_DIR   := ../DroboDext
DEXT       := org.redrobo.ReDrobo.DroboDext.dext
# Universal, and not optional. macOS 26 is the last release that runs on Intel,
# and an Intel Mac on 26 is exactly the machine that has just lost Dashboard:
# Drobo's own app is Intel-only but tops out at macOS 11. Shipping arm64 alone
# would leave the people with the strongest reason to want this unable to run
# it. The dext has been x86_64 + arm64e all along.
ARCHS      := arm64 x86_64
DEPLOY     := 26.0

# Restricted entitlements (system-extension.install, driverkit.*) are only
# honoured if a matching provisioning profile is embedded in the bundle. Without
# one AMFI SIGKILLs the app at exec, which surfaces as "Taskgated Invalid
# Signature". Drop the profiles next to this Makefile and they get embedded
# automatically.
PROFILE_APP_DEV      := ReDrobo.provisionprofile
PROFILE_DEXT_DEV     := DroboDext.provisionprofile
PROFILE_APP_RELEASE  := ReDrobo-DeveloperID.provisionprofile
PROFILE_DEXT_RELEASE := DroboDext-DeveloperID.provisionprofile

# Override either identity with:  make SIGN_ID="Apple Development: Someone (XXXX)"
ifdef RELEASE
SIGN_ID      ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Developer ID Application/{print $$2; exit}')
PROFILE_APP  := $(PROFILE_APP_RELEASE)
PROFILE_DEXT := $(PROFILE_DEXT_RELEASE)
# A Developer ID signature has to outlive its certificate: Gatekeeper checks
# that the certificate was valid on the day of signing rather than today, and
# the secure timestamp is what proves when that was. The notary service refuses
# anything signed without one. A development build needs none of this and the
# timestamp costs a round trip to Apple, so it is off by default.
TIMESTAMP    := --timestamp
else
SIGN_ID      ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Apple Development/{print $$2; exit}')
PROFILE_APP  := $(PROFILE_APP_DEV)
PROFILE_DEXT := $(PROFILE_DEXT_DEV)
TIMESTAMP    := --timestamp=none
endif

SWIFTFLAGS := -O
SOURCES    := $(wildcard *.swift)

.PHONY: all clean install check signing dext dist notarize doctor bump icon

all: $(BUNDLE)

# The icon is generated, not stored: one small Swift program draws it at every
# size iconutil wants. Editing tools/icon/make-icon.swift and running make icon
# is the whole workflow.
ICON := ReDrobo.icns

icon: $(ICON)

$(ICON): ../tools/icon/make-icon.swift
	@mkdir -p build
	xcrun swiftc -target arm64-apple-macos$(DEPLOY) -O \
		-o build/make-icon ../tools/icon/make-icon.swift
	rm -rf build/ReDrobo.iconset
	./build/make-icon build/ReDrobo.iconset
	iconutil -c icns build/ReDrobo.iconset -o $(ICON)
	@echo "built $(ICON)"

# The driver is built by its own Makefile next door.
dext:
	$(MAKE) -C $(DEXT_DIR)

build/$(APP)-%: $(SOURCES)
	@mkdir -p build
	xcrun swiftc -target $*-apple-macos$(DEPLOY) $(SWIFTFLAGS) -o $@ $(SOURCES)

$(BUNDLE): $(addprefix build/$(APP)-,$(ARCHS)) Info.plist ReDrobo.entitlements dext $(ICON)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	mkdir -p $(BUNDLE)/Contents/Resources
	mkdir -p $(BUNDLE)/Contents/Library/SystemExtensions
	cp Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(ICON) $(BUNDLE)/Contents/Resources/$(ICON)
	lipo -create $(addprefix build/$(APP)-,$(ARCHS)) \
		-output $(BUNDLE)/Contents/MacOS/$(APP)
	cp -R $(DEXT_DIR)/$(DEXT) $(BUNDLE)/Contents/Library/SystemExtensions/
	@if [ -f "$(PROFILE_DEXT)" ]; then \
		cp "$(PROFILE_DEXT)" $(BUNDLE)/Contents/Library/SystemExtensions/$(DEXT)/embedded.provisionprofile; \
		echo "==> embedded $(PROFILE_DEXT) in the dext"; \
	fi
	@if [ -f "$(PROFILE_APP)" ]; then \
		cp "$(PROFILE_APP)" $(BUNDLE)/Contents/embedded.provisionprofile; \
		echo "==> embedded $(PROFILE_APP) in the app"; \
	else \
		echo "==> NOTE: $(PROFILE_APP) not found."; \
		echo "    Restricted entitlements will not be honoured without it: the app"; \
		echo "    is SIGKILLed at launch unless the Mac boots with"; \
		echo "    amfi_get_out_of_my_way=1, and the notary service refuses it"; \
		echo "    outright. Run 'make doctor' for detail."; \
	fi
	@echo
	@echo "==> signing the dext first, then the app around it"
	codesign --force $(TIMESTAMP) --options runtime \
		--sign "$(SIGN_ID)" \
		--entitlements $(DEXT_DIR)/DroboDext.entitlements \
		$(BUNDLE)/Contents/Library/SystemExtensions/$(DEXT)
	codesign --force $(TIMESTAMP) --options runtime \
		--sign "$(SIGN_ID)" \
		--entitlements ReDrobo.entitlements \
		$(BUNDLE)
	@echo
	@echo "built $(BUNDLE)  ($$(lipo -archs $(BUNDLE)/Contents/MacOS/$(APP)))"

# The system will not activate an extension from an app outside /Applications.
install: $(BUNDLE)
	@if pgrep -x $(APP) >/dev/null; then \
		echo "==> quitting the running copy"; pkill -x $(APP) || true; sleep 1; \
	fi
	rm -rf /Applications/$(BUNDLE)
	ditto $(BUNDLE) /Applications/$(BUNDLE)
	@# Finder metadata rides along and codesign refuses any bundle carrying it,
	@# which makes sysextd reject the app before it looks for the extension.
	xattr -cr /Applications/$(BUNDLE)
	@codesign --verify --deep --strict /Applications/$(BUNDLE) \
		&& echo "installed and verified /Applications/$(BUNDLE)" \
		|| echo "installed, but the signature does NOT verify, see above"

	@echo "open it, press Install Driver, then RESTART the Mac"

# Build here, test on another Mac. Ditto keeps the signature and the symlinks
# intact, which a plain zip does not.
dist: $(BUNDLE)
	rm -f ReDrobo-app.zip
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) ReDrobo-app.zip
	@echo
	@echo "wrote $$(pwd)/ReDrobo-app.zip"
	@echo "On the target Mac, deleting BOTH copies first because ditto merges"
	@echo "into an existing directory rather than replacing it:"
	@echo "  sudo rm -rf /Applications/ReDrobo.app ./ReDrobo.app"
	@echo "  ditto -x -k ReDrobo-app.zip ."
	@echo "  sudo ditto ReDrobo.app /Applications/ReDrobo.app"
	@echo "  sudo xattr -cr /Applications/ReDrobo.app"
	@echo "  # then Install driver, then REBOOT"

# Notarization. The credentials live in the keychain and never in this file:
#
#     xcrun notarytool store-credentials
#
# which asks for a profile name, your Apple ID, the team ID and an app-specific
# password. Pass NOTARY_PROFILE if you called it something else.
NOTARY_PROFILE ?= redrobo

notarize: $(BUNDLE)
	@if [ -z "$(RELEASE)" ]; then \
		echo "Refusing: a notarized build has to be signed with Developer ID."; \
		echo "  make RELEASE=1 notarize"; \
		exit 1; \
	fi
	@mkdir -p build
	rm -f build/notarize.zip
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) build/notarize.zip
	xcrun notarytool submit build/notarize.zip \
		--keychain-profile "$(NOTARY_PROFILE)" --wait
	@# The ticket is stapled to the app, because a zip cannot carry one. That is
	@# also why the archive is rebuilt here rather than reused: the copy inside
	@# the one we submitted has no ticket in it.
	xcrun stapler staple $(BUNDLE)
	xcrun stapler validate $(BUNDLE)
	spctl -a -vvv -t install $(BUNDLE)
	rm -f ReDrobo-app.zip
	ditto -c -k --sequesterRsrc --keepParent $(BUNDLE) ReDrobo-app.zip
	@echo
	@echo "wrote $$(pwd)/ReDrobo-app.zip, notarized and stapled"
	@echo "That one installs on a Mac nobody has prepared."

# The offline checks. No hardware, no driver, no side effects: record decoding,
# the status word tables, the redundancy derivation and the device identity
# rules, against the values in docs/PROTOCOL.md.
CHECK_SOURCES := DroboRecords.swift DroboStatus.swift DroboIOKit.swift \
                 Redaction.swift Enclosure.swift

check:
	@mkdir -p build
	@xcrun swiftc -target arm64-apple-macos$(DEPLOY) \
		-o build/checks $(CHECK_SOURCES) Checks/main.swift
	@./build/checks

# What got signed, and the state of this Mac.
signing: $(BUNDLE)
	@echo "=== app ==="
	@codesign -dvvv --entitlements - $(BUNDLE) 2>&1 | grep -vE '^\s*$$'
	@echo
	@echo "=== embedded dext ==="
	@codesign -dvvv --entitlements - \
		$(BUNDLE)/Contents/Library/SystemExtensions/$(DEXT) 2>&1 | grep -vE '^\s*$$'
	@echo
	@echo "=== system state ==="
	@printf "SIP:            "; csrutil status
	@printf "dext dev mode:  "; systemextensionsctl developer 2>&1 | head -1
	@echo "activated extensions:"; systemextensionsctl list 2>&1 | tail -5

# Diagnoses the usual reasons this refuses to run.
doctor:
	@echo "=== signing ==="
	@printf "  building for    : %s\n" "$(if $(RELEASE),release (Developer ID),development)"
	@printf "  identity in use : %s\n" "$(SIGN_ID)"
	@printf "  timestamp       : %s\n" "$(TIMESTAMP)"
	@echo
	@echo "=== development profiles (self-serve, yours to make) ==="
	@if [ -f "$(PROFILE_APP_DEV)" ]; then echo "  app             : $(PROFILE_APP_DEV)"; \
		else echo "  app             : MISSING"; fi
	@if [ -f "$(PROFILE_DEXT_DEV)" ]; then echo "  dext            : $(PROFILE_DEXT_DEV)"; \
		else echo "  dext            : MISSING"; fi
	@echo
	@echo "=== release profiles (need capabilities granted by Apple) ==="
	@printf "  Developer ID    : %s\n" \
		"$$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $$2; exit}')"
	@if [ -f "$(PROFILE_APP_RELEASE)" ]; then echo "  app             : $(PROFILE_APP_RELEASE)"; \
		else echo "  app             : MISSING"; fi
	@if [ -f "$(PROFILE_DEXT_RELEASE)" ]; then echo "  dext            : $(PROFILE_DEXT_RELEASE)"; \
		else echo "  dext            : MISSING"; fi
	@echo
	@echo "=== this Mac ==="
	@printf "  SIP             : "; csrutil status | sed 's/System Integrity Protection status: //'
	@printf "  dext dev mode   : "; systemextensionsctl developer 2>&1 | head -1
	@printf "  boot-args       : "; nvram boot-args 2>/dev/null | sed 's/^boot-args\t//' || echo "(none set)"
	@echo
	@echo "=== verdict ==="
	@if [ -f "$(PROFILE_APP)" ]; then \
		echo "  Profiles present, the app should launch normally."; \
	elif nvram boot-args 2>/dev/null | grep -q amfi_get_out_of_my_way; then \
		echo "  No profiles, but AMFI enforcement is off. The app should launch."; \
	else \
		echo "  No profiles and AMFI is enforcing."; \
		echo "  The app WILL be killed at launch with 'Taskgated Invalid Signature'."; \
		echo "  Fix it one of two ways, see docs/TESTING.md:"; \
		echo "    a) put development provisioning profiles next to this Makefile"; \
		echo "    b) on a throwaway test Mac with SIP already off:"; \
		echo "         sudo nvram boot-args=\"amfi_get_out_of_my_way=1\" && sudo reboot"; \
	fi

# Every test build needs a new version. Reinstalling the same version leaves
# sysextd with two entries for the identifier, one stuck in
# terminating_for_upgrade_via_delegate, and activation then fails with a Fault.
bump:
	@python3 -c "import plistlib,sys; \
	  ps=['Info.plist','$(DEXT_DIR)/Info.plist']; \
	  [ (lambda p,d: (d.__setitem__('CFBundleVersion', str(int(d['CFBundleVersion'])+1)), \
	                  plistlib.dump(d, open(p,'wb'), sort_keys=False), \
	                  print('  %s -> build %s' % (p, d['CFBundleVersion']))) \
	    )(p, plistlib.load(open(p,'rb'))) for p in ps ]"

clean:
	rm -rf $(BUNDLE) build $(ICON)
	$(MAKE) -C $(DEXT_DIR) clean
