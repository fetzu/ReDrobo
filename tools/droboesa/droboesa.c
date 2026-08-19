/*
 * ### [   droboesa || dumps Drobo ESA records through Drobo's own kext   ] ###
 *
 * Why this exists
 * ---------------
 * macOS will not give userspace a SCSITaskUserClient for a disk that already
 * has an in-kernel driver, so the clean kext-free route is closed for a Drobo
 * (see docs/PHASE1-FINDINGS.md). On a Mac where Drobo Dashboard is still
 * installed, though, TrustedDataSCSIDriver.kext is right there and its user
 * client is an ordinary IOUserClient. This talks to it and dumps the raw ESA
 * mode page records, which is what we need to document the protocol.
 *
 * Run it on the old Mac that still runs Dashboard. Nothing here needs SIP
 * changes, Reduced Security or an unmounted volume.
 *
 * SAFETY
 * ------
 * The kext exposes 11 selectors. Selector 3 is sSetESAModePage, which WRITES
 * configuration to the enclosure. This tool can physically only issue
 * selectors 0, 1 and 2: every call goes through call_kext(), which refuses
 * anything not in ALLOWED_SELECTORS. Selector 2 is sGetESAModePage, whose only
 * effect on the wire is a SCSI MODE SENSE(10), a read.
 *
 * Selector map recovered from the kext's sMethods dispatch table at
 * __DATA,__const 0xb950 (11 entries of 24 bytes):
 *
 *     sel  method                 scIn  stIn  scOut  stOut
 *      0   sOpen                     0     0      0      0
 *      1   sClose                    0     0      0      0
 *      2   sGetESAModePage           2     0      1   1308   <- the only one we use
 *      3   sSetESAModePage           3  1308      0      0   <- NEVER
 *      4   sVendorSpecificOut        0    24      0      0
 *      5   sVendorSpecificIn         0    24      0      4
 *      6   sVendorSpecificPassThroughOut  0 32    0      0
 *      7   sVendorSpecificPassThroughIn   0 32    0      4
 *      8   sSetLoggingLevel          1     0      0      0
 *      9   sataReadCommandMethod     0    40      0     16
 *     10   sataWriteCommandMethod    0    40      0     16
 *
 * IOKit validates argument counts and sizes against that table before the
 * kext's handler ever runs, so a mistake on our side is rejected rather than
 * executed.
 *
 * Build:  make
 * Run:    sudo launchctl unload /Library/LaunchDaemons/com.datarobotics.ddservice64d.plist
 *         sudo ./droboesa --dump
 *         sudo launchctl load /Library/LaunchDaemons/com.datarobotics.ddservice64d.plist
 */

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <getopt.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------- [ CONSTANTS are the new vars ] ---------------- */

#define VERSION "0.1.0"

/* The kext's IOClass, i.e. what to look for in the IORegistry. */
#define DROBO_DRIVER_CLASS "com_TrustedData_driver_VendorSpecificType00"

/* Selector numbers, from the dispatch table above. */
#define SEL_OPEN            0
#define SEL_CLOSE           1
#define SEL_GET_ESA_PAGE    2

/* Size of _ESAModePageStruct, fixed by checkStructureOutputSize on selector 2. */
#define ESA_STRUCT_SIZE     1308

/*
 * The whitelist. Anything not in here cannot be sent, full stop. Selector 3
 * (sSetESAModePage) is deliberately absent and must stay that way.
 */
static const uint32_t ALLOWED_SELECTORS[] = { SEL_OPEN, SEL_CLOSE, SEL_GET_ESA_PAGE };

/* ---------------- [ The ESA record map, from docs/PROTOCOL.md ] ---------------- */

typedef struct {
    uint32_t    page;
    const char *name;
    const char *fields;
} esa_page_t;

static const esa_page_t ESA_PAGES[] = {
    {0x01, "ConfigInfo",      "slots, maxLuns"},
    {0x02, "CapacityInfo",    "freeCapacity(u64), usedCapacity(u64)"},
    {0x03, "SlotInfo",        "slots"},
    {0x04, "LunInfo",         "luns"},
    {0x05, "SystemSettings",  "currentTime(u32), gmtOffset(u32)"},
    {0x06, "ProtocolVersion", "major, minor"},
    {0x08, "FirmwareInfo",    "buildNumber"},
    {0x09, "StatusInfo",      "status, relayoutCount"},
    {0x30, "Options",         "yellowThreshold"},
    {0x31, "Options2",        "featureOnOffStates(u64)"},
};
static const size_t ESA_PAGE_COUNT = sizeof(ESA_PAGES) / sizeof(ESA_PAGES[0]);

/* ---------------- [ Some custom FUNCTIONS ] ---------------- */

/* Turn an IOReturn into something readable, because 0xe00002c5 tells nobody anything. */
static const char *ioreturn_name(IOReturn kr)
{
    switch (kr) {
    case kIOReturnSuccess:          return "success";
    case kIOReturnError:            return "kIOReturnError";
    case kIOReturnNoMemory:         return "kIOReturnNoMemory";
    case kIOReturnNoDevice:         return "kIOReturnNoDevice";
    case kIOReturnNotPrivileged:    return "kIOReturnNotPrivileged (try sudo)";
    case kIOReturnBadArgument:      return "kIOReturnBadArgument";
    case kIOReturnExclusiveAccess:  return "kIOReturnExclusiveAccess";
    case kIOReturnUnsupported:      return "kIOReturnUnsupported";
    case kIOReturnNotOpen:          return "kIOReturnNotOpen";
    case kIOReturnBusy:             return "kIOReturnBusy";
    default:                        return "unknown";
    }
}

/* Print a buffer the usual way, skipping long runs of zeroes. */
static void hexdump(const uint8_t *p, size_t n, const char *indent)
{
    size_t skipped = 0;
    for (size_t i = 0; i < n; i += 16) {
        size_t chunk = (n - i < 16) ? n - i : 16;

        /* Collapse all-zero lines, they are just padding in a 1308 byte struct */
        bool empty = true;
        for (size_t j = 0; j < chunk; j++)
            if (p[i + j]) { empty = false; break; }
        if (empty) { skipped++; continue; }
        if (skipped) {
            printf("%s      ... %zu zero line%s ...\n",
                   indent, skipped, skipped == 1 ? "" : "s");
            skipped = 0;
        }

        printf("%s%04zx  ", indent, i);
        for (size_t j = 0; j < 16; j++) {
            if (j < chunk) printf("%02x ", p[i + j]);
            else           printf("   ");
            if (j == 7) putchar(' ');
        }
        printf(" |");
        for (size_t j = 0; j < chunk; j++) {
            uint8_t c = p[i + j];
            putchar((c >= 0x20 && c < 0x7f) ? c : '.');
        }
        printf("|\n");
    }
    if (skipped)
        printf("%s      ... %zu trailing zero line%s ...\n",
               indent, skipped, skipped == 1 ? "" : "s");
}

/*
 * Every single call to the kext goes through here. If the selector is not on
 * the whitelist we abort rather than send it. This is the safety property the
 * whole tool rests on, so do not add a bypass.
 */
static IOReturn call_kext(io_connect_t conn, uint32_t selector,
                          const uint64_t *scalarIn, uint32_t scalarInCount,
                          uint64_t *scalarOut, uint32_t *scalarOutCount,
                          void *structOut, size_t *structOutSize)
{
    bool allowed = false;
    for (size_t i = 0; i < sizeof(ALLOWED_SELECTORS)/sizeof(ALLOWED_SELECTORS[0]); i++)
        if (ALLOWED_SELECTORS[i] == selector) { allowed = true; break; }

    if (!allowed) {
        fprintf(stderr,
            "\nREFUSING to send selector %u. This tool is read-only and only\n"
            "selectors 0, 1 and 2 are permitted. This is a bug, please report it.\n",
            selector);
        abort();
    }

    return IOConnectCallMethod(conn, selector,
                               scalarIn, scalarInCount, NULL, 0,
                               scalarOut, scalarOutCount, structOut, structOutSize);
}

/* Read one ESA record. Returns bytes received, or -1 on failure. */
static long read_esa_page(io_connect_t conn, uint32_t page, uint32_t requestedSize,
                          uint8_t *buf, size_t buflen)
{
    /*
     * Selector 2 wants exactly 2 scalars in, 1 scalar out and a 1308 byte
     * struct out. From sGetESAModePage: scalarInput[0] is the page number and
     * the second argument is the requested page size. The kext reads that
     * second value from an unexpected offset, so if a page comes back empty it
     * is worth retrying with --size (see the note in the runbook).
     */
    uint64_t scalarIn[2]  = { page, requestedSize };
    uint64_t scalarOut[8] = { 0 };
    uint32_t scalarOutCount = 1;
    size_t   structOutSize  = ESA_STRUCT_SIZE;

    if (buflen < ESA_STRUCT_SIZE) return -1;
    memset(buf, 0, buflen);

    /* Ask the kext to fill the struct. On the wire this is one MODE SENSE(10) */
    IOReturn kr = call_kext(conn, SEL_GET_ESA_PAGE,
                            scalarIn, 2, scalarOut, &scalarOutCount,
                            buf, &structOutSize);
    if (kr != kIOReturnSuccess) {
        printf("      -> failed, kr = 0x%08x  %s\n", kr, ioreturn_name(kr));
        return -1;
    }

    /* The scalar output carries the realized byte count */
    printf("      returned struct %zu bytes, scalarOut[0] = %llu\n",
           structOutSize, (unsigned long long)scalarOut[0]);
    return (long)structOutSize;
}

/* ---------------- [ MAIN ] ---------------- */

static void usage(const char *argv0)
{
    fprintf(stderr,
        "droboesa %s -- dump Drobo ESA records via Drobo's own kext (read-only)\n"
        "\n"
        "usage: %s [--dump] [--page N] [--size N] [--all-bytes]\n"
        "\n"
        "  --dump        read every known ESA record (default)\n"
        "  --page N      read only record N (decimal, or 0x.. for hex)\n"
        "  --size N      requested page size, default 1308\n"
        "  --all-bytes   do not collapse runs of zero bytes in the dump\n"
        "\n"
        "Only selectors 0, 1 and 2 of the kext can be issued. Selector 3, the\n"
        "one that writes settings to the enclosure, is not reachable from here.\n"
        "\n"
        "Stop Drobo's daemon first so it releases the device:\n"
        "  sudo launchctl unload /Library/LaunchDaemons/com.datarobotics.ddservice64d.plist\n",
        VERSION, argv0);
}

int main(int argc, char **argv)
{
    int      singlePage = -1;
    uint32_t reqSize    = ESA_STRUCT_SIZE;
    bool     allBytes   = false;

    static struct option opts[] = {
        {"dump",      no_argument,       0, 'd'},
        {"page",      required_argument, 0, 'p'},
        {"size",      required_argument, 0, 's'},
        {"all-bytes", no_argument,       0, 'a'},
        {"help",      no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };
    int c;
    while ((c = getopt_long(argc, argv, "dp:s:ah", opts, NULL)) != -1) {
        switch (c) {
        case 'd': break;                                        /* the default anyway */
        case 'p': singlePage = (int)strtol(optarg, NULL, 0); break;
        case 's': reqSize = (uint32_t)strtoul(optarg, NULL, 0); break;
        case 'a': allBytes = true; break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 2;
        }
    }

    /* Line buffered so the log stays in order when piped through tee */
    setvbuf(stdout, NULL, _IOLBF, 0);

    printf("droboesa %s -- read-only, selectors 0/1/2 only\n\n", VERSION);

    /* Find the instance of Drobo's driver in the registry */
    CFMutableDictionaryRef match = IOServiceMatching(DROBO_DRIVER_CLASS);
    if (!match) {
        fprintf(stderr, "IOServiceMatching failed\n");
        return 1;
    }

    io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, match);
    if (!svc) {
        fprintf(stderr,
            "No %s found.\n\n"
            "That class only exists when Drobo Dashboard's kext is installed and\n"
            "loaded. Run this on the Mac that still runs Dashboard, with the\n"
            "Drobo plugged in and powered.\n", DROBO_DRIVER_CLASS);
        return 1;
    }
    printf("Found %s\n", DROBO_DRIVER_CLASS);

    /* Open a user client. Type 0 is what the Drobo daemon uses */
    io_connect_t conn = MACH_PORT_NULL;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr,
            "IOServiceOpen failed: 0x%08x\n\n"
            "If this is kIOReturnBusy or kIOReturnExclusiveAccess, DDService64d\n"
            "still holds the device. Stop it first:\n"
            "  sudo launchctl unload /Library/LaunchDaemons/com.datarobotics.ddservice64d.plist\n",
            kr);
        return 1;
    }

    /* Selector 0: tell the driver we want it */
    kr = call_kext(conn, SEL_OPEN, NULL, 0, NULL, NULL, NULL, NULL);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "sOpen (selector 0) failed: 0x%08x  %s\n", kr, ioreturn_name(kr));
        if (kr == kIOReturnExclusiveAccess) {
            fprintf(stderr,
                "\nSomething else already holds the driver open, almost certainly\n"
                "DDService64d. Note that plain 'launchctl list' does NOT show it,\n"
                "because without sudo launchctl only reports the user domain.\n"
                "Check and stop it like this:\n"
                "  pgrep -x DDService64d\n"
                "  sudo launchctl unload %s\n"
                "  pgrep -x DDService64d          # should print nothing now\n"
                "Quit the Drobo Dashboard app too, then run this again.\n",
                "/Library/LaunchDaemons/com.datarobotics.ddservice64d.plist");
        }
        IOServiceClose(conn);
        return 1;
    }
    printf("User client open !\n");

    /* Read the records */
    uint8_t buf[ESA_STRUCT_SIZE];
    for (size_t i = 0; i < ESA_PAGE_COUNT; i++) {
        if (singlePage >= 0 && ESA_PAGES[i].page != (uint32_t)singlePage) continue;

        printf("\n  --- record 0x%02x  %s ---\n", ESA_PAGES[i].page, ESA_PAGES[i].name);
        printf("      expected fields: %s\n", ESA_PAGES[i].fields);

        long got = read_esa_page(conn, ESA_PAGES[i].page, reqSize, buf, sizeof(buf));
        if (got > 0)
            hexdump(buf, allBytes ? (size_t)got : (size_t)got, "      ");
    }

    /* If the caller asked for a page we do not have a name for, try it anyway */
    if (singlePage >= 0) {
        bool known = false;
        for (size_t i = 0; i < ESA_PAGE_COUNT; i++)
            if (ESA_PAGES[i].page == (uint32_t)singlePage) known = true;
        if (!known) {
            printf("\n  --- record 0x%02x  (not in the known map) ---\n", singlePage);
            long got = read_esa_page(conn, (uint32_t)singlePage, reqSize, buf, sizeof(buf));
            if (got > 0) hexdump(buf, (size_t)got, "      ");
        }
    }

    /* Selector 1, then hand the device back */
    call_kext(conn, SEL_CLOSE, NULL, 0, NULL, NULL, NULL, NULL);
    IOServiceClose(conn);

    printf("\nDone. Restart the daemon when you are finished:\n"
           "  sudo launchctl load /Library/LaunchDaemons/com.datarobotics.ddservice64d.plist\n");
    return 0;
}
