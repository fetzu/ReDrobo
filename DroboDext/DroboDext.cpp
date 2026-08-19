/* ---------------- [ DroboDext || the driver and its user client ] ---------------- */

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/OSData.h>
#include "DroboDext.h"
#include "DroboUserClient.h"
#include "DroboShared.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "DroboDext: " fmt, ##__VA_ARGS__)

/* Comes from the Makefile, which reads CFBundleVersion out of Info.plist.
   A literal here is what made this log line lie about which build was live,
   and that line is the only check the reboot trap has. */
#ifndef DROBO_DEXT_BUILD
#define DROBO_DEXT_BUILD "unstamped"
#endif

/* ---------------- [ CONSTANTS are the new vars ] ---------------- */

struct DroboDext_IVars {
    uint32_t placeholder;
};

struct DroboUserClient_IVars {
    DroboDext * provider;   /* not retained, the stack outlives us */
};

/* ---------------- [ DroboDext ] ---------------- */

bool
DroboDext::init ( void )
{
    if ( !super::init () ) return false;
    ivars = IONewZero ( DroboDext_IVars, 1 );
    return ivars != nullptr;
}

void
DroboDext::free ( void )
{
    IOSafeDeleteNULL ( ivars, DroboDext_IVars, 1 );
    super::free ();
}

kern_return_t
IMPL ( DroboDext, Start )
{
    kern_return_t ret = Start ( provider, SUPERDISPATCH );
    if ( ret != kIOReturnSuccess ) {
        LOG ( "super::Start failed 0x%x", ret );
        return ret;
    }

    uint64_t blockSize = 0;
    kern_return_t bs = UserReportMediumBlockSize ( &blockSize );
    LOG ( "UserReportMediumBlockSize -> 0x%x, blockSize %llu", bs, blockSize );

    RegisterService ();
    LOG ( "started, build " DROBO_DEXT_BUILD );
    return kIOReturnSuccess;
}

kern_return_t
IMPL ( DroboDext, Stop )
{
    LOG ( "stopping" );
    return Stop ( provider, SUPERDISPATCH );
}

kern_return_t
IMPL ( DroboDext, UserDetermineDeviceCharacteristics )
{
    /* Nothing to tune here. Enumeration must succeed so the volume mounts. */
    *result = true;
    return kIOReturnSuccess;
}

kern_return_t
IMPL ( DroboDext, NewUserClient )
{
    (void) type;   /* the family only ever asks for type 0 here */

    IOService * client = nullptr;

    /* "UserClientProperties" is the dict in Info.plist naming DroboUserClient */
    kern_return_t ret = Create ( this, "UserClientProperties", &client );
    if ( ret != kIOReturnSuccess ) {
        LOG ( "Create(UserClientProperties) failed 0x%x", ret );
        return ret;
    }

    *userClient = OSDynamicCast ( IOUserClient, client );
    if ( *userClient == nullptr ) {
        LOG ( "created object is not an IOUserClient" );
        client->release ();
        return kIOReturnError;
    }

    LOG ( "user client created" );
    return kIOReturnSuccess;
}

/* ---------------- [ DroboUserClient ] ---------------- */

bool
DroboUserClient::init ( void )
{
    if ( !super::init () ) return false;
    ivars = IONewZero ( DroboUserClient_IVars, 1 );
    return ivars != nullptr;
}

void
DroboUserClient::free ( void )
{
    IOSafeDeleteNULL ( ivars, DroboUserClient_IVars, 1 );
    super::free ();
}

kern_return_t
IMPL ( DroboUserClient, Start )
{
    kern_return_t ret = Start ( provider, SUPERDISPATCH );
    if ( ret != kIOReturnSuccess ) return ret;

    /* Remember who to send CDBs through */
    ivars->provider = OSDynamicCast ( DroboDext, provider );
    if ( ivars->provider == nullptr ) {
        LOG ( "user client provider is not a DroboDext" );
        return kIOReturnBadArgument;
    }

    LOG ( "user client started" );
    return kIOReturnSuccess;
}

kern_return_t
IMPL ( DroboUserClient, Stop )
{
    ivars->provider = nullptr;
    return Stop ( provider, SUPERDISPATCH );
}

/*
 * Issue one CDB and report what came back. Everything the diagnostics do goes
 * through here so the only variable is the CDB itself.
 */
static kern_return_t
run_cdb ( DroboDext * provider, const uint8_t cdb[16], uint64_t bufAddr,
          uint32_t bufLen, const char * what, uint64_t * gotOut )
{
    SCSIType00OutParameters out {};
    SCSIType00InParameters  in  {};

    out.fLogicalUnitNumber            = 0;
    out.fTimeoutDuration              = 30000;
    out.fRequestedByteCountOfTransfer = bufLen;
    out.fBufferDirection              = kIOMemoryDirectionIn;
    out.fDataTransferDirection        = bufLen ? kSCSIDataTransfer_FromTargetToInitiator
                                               : kSCSIDataTransfer_NoDataTransfer;
    out.fDataBufferAddr               = bufAddr;
    out.fSenseLengthRequested         = 0;
    memcpy ( out.fCommandDescriptorBlock, cdb, 16 );

    kern_return_t ret = provider->UserSendCDB ( out, &in );
    LOG ( "%{public}s: UserSendCDB -> 0x%x, scsiStatus 0x%x, serviceResponse 0x%x, got %llu",
          what, ret, in.fCompletionStatus, in.fServiceResponse,
          in.fRealizedByteCountOfTransfer );
    if ( gotOut ) *gotOut = in.fRealizedByteCountOfTransfer;
    if ( ret != kIOReturnSuccess ) return ret;
    return ( in.fCompletionStatus == kSCSITaskStatus_GOOD ) ? kIOReturnSuccess
                                                            : kIOReturnIOError;
}

/* Walk the simplest commands first, so we learn where the wall actually is. */
static void
diagnose ( DroboDext * provider, uint64_t bufAddr, uint32_t bufLen __attribute__((unused)) )
{
    uint64_t blockSize = 0;
    LOG ( "diag: UserReportMediumBlockSize -> 0x%x (%llu)",
          provider->UserReportMediumBlockSize ( &blockSize ), blockSize );

    uint8_t cdb[16] = {};

    /* TEST UNIT READY, the most harmless command in SCSI */
    memset ( cdb, 0, sizeof ( cdb ) );
    run_cdb ( provider, cdb, bufAddr, 0, "diag TEST UNIT READY", nullptr );

    /* INQUIRY, standard opcode, small read */
    memset ( cdb, 0, sizeof ( cdb ) );
    cdb[0] = 0x12; cdb[4] = 0x24;
    run_cdb ( provider, cdb, bufAddr, 0x24, "diag INQUIRY", nullptr );

    /* MODE SENSE(10) of a standard page, nothing vendor specific */
    memset ( cdb, 0, sizeof ( cdb ) );
    cdb[0] = 0x5A; cdb[2] = 0x3F; cdb[7] = 0x00; cdb[8] = 0xC0;
    run_cdb ( provider, cdb, bufAddr, 0xC0, "diag MODE SENSE all pages", nullptr );

    /* And finally the Drobo one */
    memset ( cdb, 0, sizeof ( cdb ) );
    cdb[0] = 0x5A; cdb[2] = kDroboModePage; cdb[3] = 0x01;
    cdb[7] = ( kDroboRecordSize >> 8 ); cdb[8] = ( kDroboRecordSize & 0xFF );
    run_cdb ( provider, cdb, bufAddr, kDroboRecordSize, "diag ESA page 0x01", nullptr );
}

kern_return_t
DroboUserClient::ExternalMethod ( uint64_t                           selector,
                                  IOUserClientMethodArguments      * arguments,
                                  const IOUserClientMethodDispatch * dispatch,
                                  OSObject                         * target,
                                  void                             * reference )
{
    (void) dispatch; (void) target; (void) reference;

    LOG ( "ExternalMethod entered: selector %llu, args %p, provider %p",
          selector, arguments, ivars ? ivars->provider : nullptr );

    if ( selector >= kDroboSelectorCount ) {
        LOG ( "refusing unknown selector %llu", selector );
        return kIOReturnBadArgument;
    }
    if ( arguments == nullptr ) return kIOReturnBadArgument;
    if ( ivars->provider == nullptr ) return kIOReturnNotAttached;

    uint8_t subpage = 1;
    if ( arguments->scalarInput != nullptr && arguments->scalarInputCount >= 1 )
        subpage = (uint8_t) ( arguments->scalarInput[0] & 0xFF );

    /* Somewhere for the device to put the record */
    IOBufferMemoryDescriptor * buffer = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create (
        kIOMemoryDirectionIn, kDroboRecordSize, 0, &buffer );
    if ( ret != kIOReturnSuccess || buffer == nullptr ) {
        LOG ( "buffer alloc failed 0x%x", ret );
        return ret == kIOReturnSuccess ? kIOReturnNoMemory : ret;
    }

    uint64_t addr = 0, len = 0;
    ret = buffer->Map ( 0, 0, 0, 0, &addr, &len );
    if ( ret != kIOReturnSuccess ) {
        LOG ( "buffer Map failed 0x%x", ret );
        OSSafeReleaseNULL ( buffer );
        return ret;
    }
    memset ( (void *) addr, 0, kDroboRecordSize );

    /* Selector 1 just probes and logs, there is nothing to hand back. */
    if ( selector == kDroboSelectorDiagnose ) {
        diagnose ( ivars->provider, addr, kDroboRecordSize );
        OSSafeReleaseNULL ( buffer );
        return kIOReturnSuccess;
    }

    /*
     * MODE SENSE(10):  5A 00 3A pp 00 00 00 LL LL 00
     * A standard opcode, so in principle this needs no exclusive access.
     * Selector 2 exists to test that claim: it suspends first, which the
     * framework documents as requiring the volume to be unmounted.
     */
    uint8_t cdb[16] = {};
    cdb[0] = kDroboModeSense10;
    cdb[2] = kDroboModePage;
    cdb[3] = subpage;
    cdb[7] = (uint8_t) ( kDroboRecordSize >> 8 );
    cdb[8] = (uint8_t) ( kDroboRecordSize & 0xFF );

    bool exclusive = ( selector == kDroboSelectorReadExcl );
    if ( exclusive ) {
        kern_return_t sr = ivars->provider->UserSuspendServices ();
        LOG ( "UserSuspendServices -> 0x%x", sr );
    }

    uint64_t got = 0;
    ret = run_cdb ( ivars->provider, cdb, addr, kDroboRecordSize,
                    exclusive ? "read (exclusive)" : "read", &got );

    if ( exclusive ) {
        kern_return_t rr = ivars->provider->UserResumeServices ();
        LOG ( "UserResumeServices -> 0x%x", rr );
    }

    if ( ret != kIOReturnSuccess ) {
        OSSafeReleaseNULL ( buffer );
        return ret;
    }
    if ( got == 0 || got > kDroboRecordSize ) got = kDroboRecordSize;

    /* Hand the bytes back. OSData copies, so the buffer can go. */
    arguments->structureOutput = OSData::withBytes ( (const void *) addr,
                                                     (uint32_t) got );
    if ( arguments->scalarOutput != nullptr && arguments->scalarOutputCount >= 1 ) {
        arguments->scalarOutput[0] = got;
    }

    LOG ( "record 0x%02x read, %llu bytes", subpage, got );
    OSSafeReleaseNULL ( buffer );
    return arguments->structureOutput ? kIOReturnSuccess : kIOReturnNoMemory;
}
