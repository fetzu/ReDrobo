/*
 * Constants shared by the driver, its user client and the host app.
 * Keep in sync with docs/PROTOCOL.md.
 */
#ifndef DroboShared_h
#define DroboShared_h

/* User client selectors. Read only on purpose: MODE SELECT is not exposed. */
enum {
    kDroboSelectorReadRecord = 0,   /* scalarInput[0] = ESA sub-page number   */
    kDroboSelectorDiagnose   = 1,   /* probe which framework calls are allowed */
    kDroboSelectorReadExcl   = 2,   /* same as 0, but Suspend/Resume around it */
    kDroboSelectorCount
};

/* One ESA record, matching the old kext's _ESAModePageStruct. */
#define kDroboRecordSize 1308

/* See docs/PROTOCOL.md. Standard SPC opcode, so no exclusive access needed. */
#define kDroboModeSense10   0x5A
#define kDroboModePage      0x3A

#endif /* DroboShared_h */
