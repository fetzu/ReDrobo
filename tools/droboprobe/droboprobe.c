/*
 * droboprobe -- read Drobo "ESA" management mode pages without any kext.
 *
 * Background
 * ----------
 * Drobo Dashboard talked to the enclosure through a third-party kernel
 * extension (TrustedDataSCSIDriver.kext, com.TrustedData.driver.VendorSpecificType00)
 * which exposed an IOUserClient to the DDService64d daemon.
 *
 * Reversing that kext shows the management channel is not exotic: it is a
 * plain SCSI MODE SENSE(10) / MODE SELECT(10) against vendor mode page 0x3A,
 * using the sub-page code to select which "ESA" record you want.
 *
 * From com_TrustedData_driver_VendorSpecificType00::GetModePage:
 *
 *     opcode        = 0x5A                (MODE SENSE 10)
 *     direction     = 0x02                (target -> initiator)
 *     LLBAA=0, DBD=0, PC=0
 *     PAGE_CODE     = 0x3A
 *     SUB_PAGE_CODE = <ESA page number>
 *     ALLOC_LENGTH  = caller supplied u16
 *     CONTROL       = 0x00
 *
 * ...which assembles to the standard 10-byte CDB:
 *
 *     5A 00 3A pp 00 00 00 LL LL 00
 *
 * Because 0x5A is a standard SPC opcode (not a vendor opcode in 0xC0-0xFF),
 * this command is reachable from userspace through Apple's own, still-shipping
 * SCSITaskUserClient -- no third-party kernel code required.
 *
 * This tool is READ ONLY. It never issues MODE SELECT (0x55) and never writes
 * to the device.
 *
 * Caveat: SCSITaskDeviceInterface::ObtainExclusiveAccess returns kIOReturnBusy
 * while a volume from the device is still mounted, so unmount the Drobo's
 * volume(s) first (diskutil unmountDisk), then run this. The disk stays
 * powered and enumerated; only the filesystem is detached.
 *
 * Build:  make
 * Run:    ./droboprobe --list
 *         ./droboprobe --dump
 */

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <IOKit/scsi/SCSICommandOperationCodes.h>
#include <getopt.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Protocol constants recovered from TrustedDataSCSIDriver.kext 1.9.1  */
/* ------------------------------------------------------------------ */

#define DROBO_MODE_PAGE 0x3A /* vendor mode page carrying every ESA record */

typedef struct {
    uint8_t     subpage;
    const char *name;
    const char *fields; /* field names seen in the kext's IOLog strings */
} esa_page_t;

/*
 * Sub-page numbers come from the jump table in
 * com_TrustedData_driver_VendorSpecificType00::getESAModePage; the human
 * names come from the IOLog format strings emitted right after each
 * GetModePage() call. Sub-page 0x07 is absent from the dispatch table.
 */
static const esa_page_t kESAPages[] = {
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
static const size_t kESAPageCount = sizeof(kESAPages) / sizeof(kESAPages[0]);

/* ------------------------------------------------------------------ */
/* Helpers                                                            */
/* ------------------------------------------------------------------ */

static void hexdump(const uint8_t *p, size_t n, const char *indent)
{
    for (size_t i = 0; i < n; i += 16) {
        printf("%s%04zx  ", indent, i);
        for (size_t j = 0; j < 16; j++) {
            if (i + j < n) printf("%02x ", p[i + j]);
            else           printf("   ");
            if (j == 7) putchar(' ');
        }
        printf(" |");
        for (size_t j = 0; j < 16 && i + j < n; j++) {
            uint8_t c = p[i + j];
            putchar((c >= 0x20 && c < 0x7f) ? c : '.');
        }
        printf("|\n");
    }
}

static char *cf_string_dup(CFStringRef s)
{
    if (!s) return NULL;
    CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s),
                                                    kCFStringEncodingUTF8) + 1;
    char *buf = calloc(1, (size_t)max);
    if (!buf) return NULL;
    if (!CFStringGetCString(s, buf, max, kCFStringEncodingUTF8)) {
        free(buf);
        return NULL;
    }
    return buf;
}

/* Recursively search a CF property tree for a string containing `needle`. */
static bool cf_tree_contains(CFTypeRef obj, const char *needle, int depth)
{
    if (!obj || depth > 6) return false;

    CFTypeID type = CFGetTypeID(obj);
    if (type == CFStringGetTypeID()) {
        char *s = cf_string_dup((CFStringRef)obj);
        if (!s) return false;
        bool hit = strcasestr(s, needle) != NULL;
        free(s);
        return hit;
    }
    if (type == CFDictionaryGetTypeID()) {
        CFDictionaryRef d = (CFDictionaryRef)obj;
        CFIndex n = CFDictionaryGetCount(d);
        if (n <= 0) return false;
        const void **vals = calloc((size_t)n, sizeof(void *));
        if (!vals) return false;
        CFDictionaryGetKeysAndValues(d, NULL, vals);
        bool hit = false;
        for (CFIndex i = 0; i < n && !hit; i++)
            hit = cf_tree_contains(vals[i], needle, depth + 1);
        free(vals);
        return hit;
    }
    if (type == CFArrayGetTypeID()) {
        CFArrayRef a = (CFArrayRef)obj;
        CFIndex n = CFArrayGetCount(a);
        for (CFIndex i = 0; i < n; i++)
            if (cf_tree_contains(CFArrayGetValueAtIndex(a, i), needle, depth + 1))
                return true;
    }
    return false;
}

/* Pull a human label out of the nub's property tree for display. */
static void describe_service(io_service_t svc, char *out, size_t outlen)
{
    out[0] = '\0';
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0)
        != KERN_SUCCESS || !props)
        return;

    /*
     * On a real device the nub turns out to be an IOSCSILogicalUnitNub (a
     * subclass of IOSCSIPeripheralDeviceNub, which is why IOProviderClass
     * matching still finds it). It carries the INQUIRY strings flat, as
     * "Vendor Identification" / "Product Identification". The nested
     * "Device Characteristics" dict lives further down the stack on
     * IOBlockStorageServices, so read the flat keys first.
     */
    char *vendor  = cf_string_dup(CFDictionaryGetValue(props, CFSTR("Vendor Identification")));
    char *product = cf_string_dup(CFDictionaryGetValue(props, CFSTR("Product Identification")));
    char *rev     = cf_string_dup(CFDictionaryGetValue(props, CFSTR("Product Revision Level")));

    /* Fall back to the nested dict for anything that publishes it that way. */
    if (!vendor && !product) {
        CFDictionaryRef dc = CFDictionaryGetValue(props, CFSTR("Device Characteristics"));
        if (dc && CFGetTypeID(dc) == CFDictionaryGetTypeID()) {
            vendor  = cf_string_dup(CFDictionaryGetValue(dc, CFSTR("Vendor Name")));
            product = cf_string_dup(CFDictionaryGetValue(dc, CFSTR("Product Name")));
            if (!rev)
                rev = cf_string_dup(CFDictionaryGetValue(dc, CFSTR("Product Revision Level")));
        }
    }

    snprintf(out, outlen, "%s %s%s%s",
             vendor  ? vendor  : "?",
             product ? product : "?",
             rev ? " rev " : "", rev ? rev : "");
    free(vendor); free(product); free(rev);
    CFRelease(props);
}

static bool service_looks_like_drobo(io_service_t svc)
{
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0)
        != KERN_SUCCESS || !props)
        return false;
    bool hit = cf_tree_contains(props, "drobo", 0) ||
               cf_tree_contains(props, "trusted", 0);
    CFRelease(props);
    return hit;
}

/* ------------------------------------------------------------------ */
/* SCSITaskLib plumbing                                               */
/* ------------------------------------------------------------------ */

typedef struct {
    SCSITaskDeviceInterface **dev;
    IOCFPlugInInterface     **plugin;
    bool                      exclusive;
} drobo_dev_t;

/*
 * Open the SCSITaskUserClient on a nub.
 *
 * With check_only set, this stops after QueryInterface and never calls
 * ObtainExclusiveAccess. Nothing is sent to the device on that path: it only
 * answers "does this nub expose a SCSITaskUserClient at all?", which is worth
 * knowing before anyone unmounts a volume.
 */
static bool open_device(io_service_t svc, drobo_dev_t *out, bool check_only)
{
    memset(out, 0, sizeof(*out));
    SInt32 score = 0;

    kern_return_t kr = IOCreatePlugInInterfaceForService(
        svc, kIOSCSITaskDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
        &out->plugin, &score);
    if (kr != KERN_SUCCESS || !out->plugin) {
        fprintf(stderr,
                "  IOCreatePlugInInterfaceForService failed (0x%08x).\n"
                "  This device has no SCSITaskUserClient. Check that its\n"
                "  'SCSITaskDeviceCategory' property is 'SCSITaskUserClientDevice'.\n",
                kr);
        return false;
    }

    HRESULT hr = (*out->plugin)->QueryInterface(
        out->plugin, CFUUIDGetUUIDBytes(kIOSCSITaskDeviceInterfaceID),
        (LPVOID *)&out->dev);
    if (hr != S_OK || !out->dev) {
        fprintf(stderr, "  QueryInterface(SCSITaskDeviceInterface) failed.\n");
        IODestroyPlugInInterface(out->plugin);
        out->plugin = NULL;
        return false;
    }

    /* The user client exists. That is all --check wanted to know. */
    if (check_only) {
        printf("  SCSITaskUserClient : available\n");
        printf("  exclusive access   : %s\n",
               (*out->dev)->IsExclusiveAccessAvailable(out->dev)
                   ? "reported available"
                   : "already held by someone else");
        return true;
    }

    IOReturn ir = (*out->dev)->ObtainExclusiveAccess(out->dev);
    if (ir != kIOReturnSuccess) {
        if (ir == kIOReturnBusy) {
            fprintf(stderr,
                "  ObtainExclusiveAccess: kIOReturnBusy -- a volume is still mounted.\n"
                "  Unmount it first, e.g.:  diskutil unmountDisk /dev/diskN\n"
                "  (unmountDisk detaches the filesystem but leaves the device attached)\n");
        } else if (ir == kIOReturnExclusiveAccess) {
            fprintf(stderr, "  ObtainExclusiveAccess: another process holds the device.\n");
        } else {
            fprintf(stderr, "  ObtainExclusiveAccess failed: 0x%08x\n", ir);
        }
        (*out->dev)->Release(out->dev);
        IODestroyPlugInInterface(out->plugin);
        memset(out, 0, sizeof(*out));
        return false;
    }
    out->exclusive = true;
    return true;
}

static void close_device(drobo_dev_t *d)
{
    if (d->dev) {
        if (d->exclusive) (*d->dev)->ReleaseExclusiveAccess(d->dev);
        (*d->dev)->Release(d->dev);
    }
    if (d->plugin) IODestroyPlugInInterface(d->plugin);
    memset(d, 0, sizeof(*d));
}

/*
 * Execute one CDB. Returns true when the task completed with GOOD status.
 * `*realized` receives the number of bytes actually transferred in.
 */
static bool scsi_in(drobo_dev_t *d, const uint8_t *cdb, uint8_t cdbLen,
                    void *buf, size_t buflen, UInt64 *realized, bool quiet)
{
    SCSITaskInterface **task = (*d->dev)->CreateSCSITask(d->dev);
    if (!task) {
        fprintf(stderr, "  CreateSCSITask failed\n");
        return false;
    }

    memset(buf, 0, buflen);

    SCSITaskSGElement sg = { .address = (uintptr_t)buf, .length = (UInt32)buflen };
    SCSI_Sense_Data   sense;
    SCSITaskStatus    status = kSCSITaskStatus_No_Status;
    UInt64            got = 0;
    bool              ok = false;

    memset(&sense, 0, sizeof(sense));

    if ((*task)->SetCommandDescriptorBlock(task, (UInt8 *)cdb, cdbLen) != kIOReturnSuccess)
        goto done;
    if ((*task)->SetScatterGatherEntries(task, &sg, 1, buflen,
                                         kSCSIDataTransfer_FromTargetToInitiator)
        != kIOReturnSuccess)
        goto done;
    if ((*task)->SetTimeoutDuration(task, 30000) != kIOReturnSuccess)
        goto done;

    if ((*task)->ExecuteTaskSync(task, &sense, &status, &got) != kIOReturnSuccess) {
        if (!quiet) fprintf(stderr, "  ExecuteTaskSync failed\n");
        goto done;
    }

    if (status != kSCSITaskStatus_GOOD) {
        if (!quiet) {
            fprintf(stderr, "  SCSI status 0x%02x", status);
            if (status == kSCSITaskStatus_CHECK_CONDITION) {
                fprintf(stderr, " CHECK CONDITION  sense key=0x%02x asc=0x%02x ascq=0x%02x",
                        sense.SENSE_KEY & 0x0F,
                        sense.ADDITIONAL_SENSE_CODE,
                        sense.ADDITIONAL_SENSE_CODE_QUALIFIER);
            }
            fprintf(stderr, "\n");
        }
        goto done;
    }
    ok = true;

done:
    if (realized) *realized = got;
    (*task)->Release(task);
    return ok;
}

/* Build the exact CDB the Drobo kext built. */
static void build_mode_sense10(uint8_t cdb[10], uint8_t page, uint8_t subpage,
                               uint16_t allocLen)
{
    cdb[0] = 0x5A;                    /* MODE SENSE(10)                 */
    cdb[1] = 0x00;                    /* LLBAA=0, DBD=0                 */
    cdb[2] = (uint8_t)(0x00 | (page & 0x3F)); /* PC=0 | PAGE CODE       */
    cdb[3] = subpage;                 /* SUB PAGE CODE                  */
    cdb[4] = 0x00;
    cdb[5] = 0x00;
    cdb[6] = 0x00;
    cdb[7] = (uint8_t)(allocLen >> 8);
    cdb[8] = (uint8_t)(allocLen & 0xFF);
    cdb[9] = 0x00;                    /* CONTROL                        */
}

/* ------------------------------------------------------------------ */
/* Commands                                                           */
/* ------------------------------------------------------------------ */

static void do_inquiry(drobo_dev_t *d)
{
    uint8_t cdb[6] = {0x12, 0x00, 0x00, 0x00, 0x60, 0x00};
    uint8_t buf[0x60];
    UInt64  got = 0;

    if (!scsi_in(d, cdb, sizeof(cdb), buf, sizeof(buf), &got, false)) {
        printf("  INQUIRY failed\n");
        return;
    }
    char vendor[9] = {0}, product[17] = {0}, rev[5] = {0};
    memcpy(vendor,  buf + 8,  8);
    memcpy(product, buf + 16, 16);
    memcpy(rev,     buf + 32, 4);
    printf("  INQUIRY : vendor='%s' product='%s' rev='%s' periph-type=0x%02x\n",
           vendor, product, rev, buf[0] & 0x1F);
}

static void dump_page(drobo_dev_t *d, uint8_t subpage, const char *name,
                      const char *fields, bool raw)
{
    uint8_t  cdb[10];
    uint8_t  buf[4096];
    UInt64   got = 0;

    /* First ask for a modest amount; the mode parameter header tells us
     * how much the device actually has. */
    build_mode_sense10(cdb, DROBO_MODE_PAGE, subpage, sizeof(buf) > 0xFFFF ? 0xFFFF
                                                                           : (uint16_t)sizeof(buf));

    printf("\n  --- sub-page 0x%02x  %s ---\n", subpage, name ? name : "(unknown)");
    printf("      CDB: ");
    for (int i = 0; i < 10; i++) printf("%02x ", cdb[i]);
    printf("\n");

    if (!scsi_in(d, cdb, sizeof(cdb), buf, sizeof(buf), &got, false)) {
        printf("      -> not supported / failed\n");
        return;
    }

    if (got < 8) {
        printf("      -> short reply (%llu bytes)\n", (unsigned long long)got);
        if (got) hexdump(buf, (size_t)got, "      ");
        return;
    }

    uint16_t modeDataLen = (uint16_t)((buf[0] << 8) | buf[1]);
    uint16_t blockDescLen = (uint16_t)((buf[6] << 8) | buf[7]);
    printf("      mode data length = %u, block descriptor length = %u, got %llu bytes\n",
           modeDataLen, blockDescLen, (unsigned long long)got);

    size_t pageOff = 8 + blockDescLen;
    if (pageOff < got) {
        const uint8_t *pg = buf + pageOff;
        size_t pgLen = (size_t)got - pageOff;
        bool spf = (pg[0] & 0x40) != 0;
        printf("      page code = 0x%02x  SPF=%d  subpage = 0x%02x\n",
               pg[0] & 0x3F, spf, spf ? pg[1] : 0);
        if (fields) printf("      expected fields: %s\n", fields);
        printf("      payload (%zu bytes):\n", pgLen);
        hexdump(pg, pgLen, "        ");
    } else if (raw) {
        hexdump(buf, (size_t)got, "        ");
    }
}

/* ------------------------------------------------------------------ */

static void usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s [--list] [--dump] [--page N] [--index N] [--any] [--raw]\n"
        "\n"
        "  --list      list candidate SCSI peripheral devices and exit\n"
        "  --check     report whether a SCSITaskUserClient exists (sends nothing)\n"
        "  --dump      read every known Drobo ESA mode page (default action)\n"
        "  --page N    read only sub-page N (decimal, or 0x.. for hex)\n"
        "  --index N   operate on device N from --list (default: first Drobo found)\n"
        "  --any       do not filter for Drobo; use with --index\n"
        "  --raw       always hexdump the full MODE SENSE reply\n"
        "\n"
        "This tool is read-only: it issues MODE SENSE(10) and INQUIRY only.\n"
        "Unmount the Drobo's volumes first (diskutil unmountDisk /dev/diskN).\n",
        argv0);
}

int main(int argc, char **argv)
{
    bool doList = false, doDump = false, raw = false, any = false, doCheck = false;
    int  wantIndex = -1, singlePage = -1;

    static struct option opts[] = {
        {"list",  no_argument,       0, 'l'},
        {"check", no_argument,       0, 'k'},
        {"dump",  no_argument,       0, 'd'},
        {"page",  required_argument, 0, 'p'},
        {"index", required_argument, 0, 'i'},
        {"any",   no_argument,       0, 'a'},
        {"raw",   no_argument,       0, 'r'},
        {"help",  no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };
    int c;
    while ((c = getopt_long(argc, argv, "lkdp:i:arh", opts, NULL)) != -1) {
        switch (c) {
        case 'l': doList = true; break;
        case 'k': doCheck = true; break;
        case 'd': doDump = true; break;
        case 'p': singlePage = (int)strtol(optarg, NULL, 0); break;
        case 'i': wantIndex = (int)strtol(optarg, NULL, 0); break;
        case 'a': any = true; break;
        case 'r': raw = true; break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 2;
        }
    }
    if (!doList && !doCheck && !doDump && singlePage < 0) doDump = true;

    /* SCSITaskUserClientIniter merges its properties onto the nub itself,
     * so the nub is what we match and what we open. */
    CFMutableDictionaryRef match = IOServiceMatching("IOSCSIPeripheralDeviceNub");
    if (!match) {
        fprintf(stderr, "IOServiceMatching failed\n");
        return 1;
    }

    /* MACH_PORT_NULL selects the default IOKit main port on every macOS version. */
    io_iterator_t it = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, match, &it) != KERN_SUCCESS) {
        fprintf(stderr, "IOServiceGetMatchingServices failed\n");
        return 1;
    }

    io_service_t svc, chosen = IO_OBJECT_NULL;
    int index = 0, chosenIndex = -1;
    char label[256];

    while ((svc = IOIteratorNext(it))) {
        describe_service(svc, label, sizeof(label));

        CFTypeRef cat = IORegistryEntryCreateCFProperty(
            svc, CFSTR(kIOPropertySCSITaskDeviceCategory), kCFAllocatorDefault, 0);
        char *catStr = (cat && CFGetTypeID(cat) == CFStringGetTypeID())
                       ? cf_string_dup((CFStringRef)cat) : NULL;
        bool isDrobo = service_looks_like_drobo(svc);

        if (doList) {
            printf("[%d] %-40s  category=%-24s %s\n", index,
                   label[0] ? label : "(unnamed)",
                   catStr ? catStr : "(none)",
                   isDrobo ? "<- looks like a Drobo" : "");
        }

        bool pick = (wantIndex >= 0) ? (index == wantIndex)
                                     : (!any && isDrobo);
        if (pick && chosen == IO_OBJECT_NULL) {
            chosen = svc;
            chosenIndex = index;
        } else {
            IOObjectRelease(svc);
        }

        free(catStr);
        if (cat) CFRelease(cat);
        index++;
    }
    IOObjectRelease(it);

    if (index == 0) {
        fprintf(stderr, "No IOSCSIPeripheralDeviceNub found. Is the Drobo plugged in and powered?\n");
        return 1;
    }
    if (doList) {
        if (!doCheck && !doDump && singlePage < 0) return 0;
    }
    if (chosen == IO_OBJECT_NULL) {
        fprintf(stderr,
            "No Drobo found among %d SCSI peripheral device(s).\n"
            "Run with --list to see them, then --any --index N to force one.\n", index);
        return 1;
    }

    describe_service(chosen, label, sizeof(label));
    printf("Using device [%d]: %s\n", chosenIndex, label[0] ? label : "(unnamed)");

    drobo_dev_t dev;
    if (!open_device(chosen, &dev, doCheck)) {
        IOObjectRelease(chosen);
        return 1;
    }
    IOObjectRelease(chosen);

    /* --check stops here: nothing has been sent to the device. */
    if (doCheck) {
        close_device(&dev);
        return 0;
    }

    do_inquiry(&dev);

    if (singlePage >= 0) {
        const char *name = NULL, *fields = NULL;
        for (size_t i = 0; i < kESAPageCount; i++)
            if (kESAPages[i].subpage == (uint8_t)singlePage) {
                name = kESAPages[i].name;
                fields = kESAPages[i].fields;
            }
        dump_page(&dev, (uint8_t)singlePage, name, fields, raw);
    } else {
        for (size_t i = 0; i < kESAPageCount; i++)
            dump_page(&dev, kESAPages[i].subpage, kESAPages[i].name,
                      kESAPages[i].fields, raw);
    }

    close_device(&dev);
    printf("\nDone. Remember to remount: diskutil mountDisk /dev/diskN\n");
    return 0;
}
