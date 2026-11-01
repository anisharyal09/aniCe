// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Anish Aryal
// Adapts aniKey's GPL HIDP/SDP transport into aniCe's bounded app-level Bluetooth owner.
#import <AppKit/AppKit.h>
#import <IOBluetooth/IOBluetooth.h>
#import <math.h>
#import <string.h>
#import <ctype.h>
#import "ClassicHIDAdapter.h"

static NSData *HIDBytes(const uint8_t *bytes, NSUInteger count) {
    return [NSData dataWithBytes:bytes length:count];
}

static NSString *HIDIOError(NSString *stage, IOReturn result) {
    return [NSString stringWithFormat:@"%@ failed (IOBluetooth 0x%08X).", stage, (unsigned)result];
}

static void HIDPump(NSTimeInterval seconds) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    do {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) break;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(remaining, 0.01)]];
    } while (YES);
}

static NSDictionary *HIDSDPNumber(unsigned value, unsigned size) {
    return @{@"DataElementType": @1, @"DataElementSize": @(size), @"DataElementValue": @(value)};
}

static NSDictionary *HIDSDPBoolean(BOOL value) {
    return @{@"DataElementType": @5, @"DataElementValue": @(value)};
}

static NSData *HIDSDPUUID(uint16_t value) {
    const uint8_t bytes[] = {(uint8_t)(value >> 8), (uint8_t)value};
    return HIDBytes(bytes, sizeof(bytes));
}

static NSDictionary *HIDServiceDictionary(void) {
    NSDictionary *attributes = @{
        @"0000": @65536,
        @"0001": @[HIDSDPUUID(0x1124)],
        @"0004": @[@[HIDSDPUUID(0x0100), HIDSDPNumber(0x0011, 2)], @[HIDSDPUUID(0x0011)]],
        @"0005": @[HIDSDPUUID(0x1002)],
        @"0006": @[HIDSDPNumber(0x656E, 2), HIDSDPNumber(106, 2), HIDSDPNumber(0x0100, 2)],
        @"0009": @[@[HIDSDPUUID(0x1124), HIDSDPNumber(0x0101, 2)]],
        @"000D": @[@[@[HIDSDPUUID(0x0100), HIDSDPNumber(0x0013, 2)], @[HIDSDPUUID(0x0011)]]],
        @"0100": @"aniCe Keyboard and Trackpad",
        @"0101": @"Native macOS input for aniCe-trusted Android phones",
        @"0102": @"aniCe",
        @"0201": HIDSDPNumber(0x0111, 2), @"0202": HIDSDPNumber(0xC0, 1),
        @"0203": HIDSDPNumber(33, 1), @"0204": HIDSDPBoolean(YES), @"0205": HIDSDPBoolean(YES),
        @"0206": @[@[HIDSDPNumber(0x22, 1), @{@"DataElementType": @4, @"DataElementValue": [AniCeHIDProtocol reportDescriptor]}]],
        @"0207": @[@[HIDSDPNumber(0x0409, 2), HIDSDPNumber(0x0100, 2)]],
        @"0209": HIDSDPBoolean(NO), @"020A": HIDSDPBoolean(NO),
        @"020B": HIDSDPNumber(0x0101, 2), @"020C": HIDSDPNumber(0x1F40, 2),
        @"020D": HIDSDPBoolean(NO), @"020E": HIDSDPBoolean(YES),
        @"LocalAttributes": @{@"Persistent": @NO}
    };
    NSDictionary *names = @{
        @"0000": @"ServiceRecordHandle", @"0001": @"ServiceClassIDList",
        @"0004": @"ProtocolDescriptorList", @"0005": @"BrowseGroupList",
        @"0006": @"LanguageBaseAttributeIDList", @"0009": @"BluetoothProfileDescriptorList",
        @"000D": @"AdditionalProtocolDescriptorLists", @"0100": @"ServiceName",
        @"0101": @"ServiceDescription", @"0102": @"ProviderName",
        @"0201": @"HIDParserVersion", @"0202": @"HIDDeviceSubclass", @"0203": @"HIDCountryCode",
        @"0204": @"HIDVirtualCable", @"0205": @"HIDReconnectInitiate", @"0206": @"HIDDescriptorList",
        @"0207": @"HIDLANGIDBaseList", @"0209": @"HIDBatteryPower", @"020A": @"HIDRemoteWake",
        @"020B": @"HIDProfileVersion", @"020C": @"HIDSupervisionTimeout",
        @"020D": @"HIDNormallyConnectable", @"020E": @"HIDBootDevice"
    };
    NSMutableDictionary *service = [NSMutableDictionary dictionary];
    for (NSString *key in attributes) {
        NSString *name = names[key] ? [NSString stringWithFormat:@"%@ - %@", key, names[key]] : key;
        service[name] = attributes[key];
    }
    return service;
}

static BOOL HIDServiceHasExpectedDescriptor(IOBluetoothSDPServiceRecord *record) {
    for (IOBluetoothSDPDataElement *element in [[record getAttributeDataElement:0x0206] getArrayValue]) {
        NSArray<IOBluetoothSDPDataElement *> *entry = [element getArrayValue];
        if (entry.count == 2 && [entry[0].getNumberValue unsignedIntValue] == 0x22)
            return [entry[1].getValue isEqual:[AniCeHIDProtocol reportDescriptor]];
    }
    return NO;
}

static NSString *HIDServiceValidationError(IOBluetoothSDPServiceRecord *record) {
    if (!HIDServiceHasExpectedDescriptor(record)) return @"The published HID descriptor did not match aniCe's input reports.";
    BluetoothL2CAPPSM control = 0;
    IOReturn result = [record getL2CAPPSM:&control];
    if (result != kIOReturnSuccess) return HIDIOError(@"Reading the published control PSM", result);
    if (control != 0x0011) return @"The published control channel did not match PSM 0x0011.";
    NSArray *controlProtocols = [[record getAttributeDataElement:0x0004] getArrayValue];
    NSArray *controlHIDP = controlProtocols.count == 2 ? [controlProtocols[1] getArrayValue] : nil;
    if (controlHIDP.count != 1 || ![[controlHIDP[0] getUUIDValue] isEqualToUUID:[IOBluetoothSDPUUID uuid16:0x0011]])
        return @"The published control protocol list is malformed.";
    NSArray *lists = [[record getAttributeDataElement:0x000D] getArrayValue];
    NSArray *protocols = lists.count == 1 ? [lists[0] getArrayValue] : nil;
    NSArray *l2cap = protocols.count == 2 ? [protocols[0] getArrayValue] : nil;
    NSArray *hidp = protocols.count == 2 ? [protocols[1] getArrayValue] : nil;
    if (l2cap.count != 2 || hidp.count != 1 ||
        ![[l2cap[0] getUUIDValue] isEqualToUUID:[IOBluetoothSDPUUID uuid16:0x0100]] ||
        ![[hidp[0] getUUIDValue] isEqualToUUID:[IOBluetoothSDPUUID uuid16:0x0011]] || ![l2cap[1] getNumberValue])
        return @"The published interrupt protocol list is malformed.";
    if ([[l2cap[1] getNumberValue] unsignedIntValue] != 0x0013)
        return @"The published interrupt channel did not match PSM 0x0013.";
    return nil;
}

@interface AniCeHIDProtocol ()
@property(nonatomic, readwrite) NSUInteger protocolMode;
@property(nonatomic, readwrite, getter=isSuspended) BOOL suspended;
@property(nonatomic, readwrite) BOOL unplugRequested;
@property(nonatomic, readwrite) uint8_t leds;
@property(nonatomic, readwrite) NSData *keyboardReport;
@property(nonatomic, readwrite) NSData *mouseReport;
@property(nonatomic, readwrite) uint16_t consumerControls;
@end

@implementation AniCeHIDProtocol
+ (NSDictionary *)serviceRecordDictionary { return HIDServiceDictionary(); }
+ (NSString *)serviceRecordValidationError:(IOBluetoothSDPServiceRecord *)record { return HIDServiceValidationError(record); }

+ (NSData *)reportDescriptor {
    static NSData *descriptor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint8_t bytes[] = {
            0x05,0x01, 0x09,0x06, 0xA1,0x01, 0x85,0x01,
            0x05,0x07, 0x19,0xE0, 0x29,0xE7, 0x15,0x00, 0x25,0x01,
            0x75,0x01, 0x95,0x08, 0x81,0x02,
            0x75,0x08, 0x95,0x01, 0x81,0x01,
            0x05,0x08, 0x19,0x01, 0x29,0x05, 0x75,0x01, 0x95,0x05, 0x91,0x02,
            0x75,0x03, 0x95,0x01, 0x91,0x01,
            0x05,0x07, 0x19,0x00, 0x29,0x65, 0x15,0x00, 0x25,0x65,
            0x75,0x08, 0x95,0x06, 0x81,0x00,
            0x95,0x01, 0x81,0x03, // Neutral tail matches the composite keyboard descriptor cached by Android.
            0xC0,
            0x05,0x0C, 0x09,0x01, 0xA1,0x01, 0x85,0x02,
            0x15,0x00, 0x25,0x01, 0x75,0x01,
            0x0A,0x24,0x02, 0x95,0x01, 0x81,0x02,
            0x81,0x03,
            0x0A,0x23,0x02, 0x81,0x02,
            0x95,0x05, 0x81,0x03,
            0x75,0x08, 0x95,0x01, 0x81,0x03, 0xC0,
            0x05,0x01, 0x09,0x02, 0xA1,0x01, 0x85,0x0A,
            0x09,0x01, 0xA1,0x00, 0x05,0x09, 0x19,0x01, 0x29,0x02,
            0x15,0x00, 0x25,0x01, 0x75,0x01, 0x95,0x02, 0x81,0x02,
            0x75,0x06, 0x95,0x01, 0x81,0x01,
            0x05,0x01, 0x09,0x30, 0x09,0x31, 0x09,0x32, 0x09,0x38, 0x15,0x81, 0x25,0x7F,
            0x75,0x08, 0x95,0x04, 0x81,0x06, 0xC0,0xC0,
        };
        descriptor = HIDBytes(bytes, sizeof(bytes));
    });
    return descriptor;
}

+ (NSString *)normalizedAddress:(NSString *)address {
    NSMutableString *compact = [NSMutableString string];
    for (NSUInteger i = 0; i < address.length; i++) {
        unichar c = [address characterAtIndex:i];
        if (c == ':' || c == '-') continue;
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f'))) return nil;
        [compact appendFormat:@"%C", (unichar)toupper((int)c)];
    }
    if (compact.length != 12) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:6];
    for (NSUInteger i = 0; i < 12; i += 2) [parts addObject:[compact substringWithRange:NSMakeRange(i, 2)]];
    return [parts componentsJoinedByString:@":"];
}

+ (NSArray<NSNumber *> *)keyForASCIICharacter:(unichar)c {
    uint8_t usage = 0, modifiers = 0;
    if (c >= 'a' && c <= 'z') usage = (uint8_t)(0x04 + c - 'a');
    else if (c >= 'A' && c <= 'Z') { usage = (uint8_t)(0x04 + c - 'A'); modifiers = 0x02; }
    else if (c >= '1' && c <= '9') usage = (uint8_t)(0x1E + c - '1');
    else if (c == '0') usage = 0x27;
    else {
        NSString *plain = @"\r\n\t \b-=[]\\;'/`,.";
        const uint8_t plainUsages[] = {0x28,0x28,0x2B,0x2C,0x2A,0x2D,0x2E,0x2F,0x30,0x31,0x33,0x34,0x38,0x35,0x36,0x37};
        NSRange range = [plain rangeOfString:[NSString stringWithCharacters:&c length:1]];
        if (range.location != NSNotFound) usage = plainUsages[range.location];
        else {
            NSString *shifted = @"!@#$%^&*()_+{}|:\"?~<>";
            const uint8_t shiftedUsages[] = {0x1E,0x1F,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x2D,0x2E,0x2F,0x30,0x31,0x33,0x34,0x38,0x35,0x36,0x37};
            range = [shifted rangeOfString:[NSString stringWithCharacters:&c length:1]];
            if (range.location == NSNotFound) return nil;
            usage = shiftedUsages[range.location]; modifiers = 0x02;
        }
    }
    return @[@(usage), @(modifiers)];
}

+ (uint8_t)usageForMacKeyCode:(unsigned short)code {
    static const uint8_t map[128] = {
        [0x00]=0x04,[0x01]=0x16,[0x02]=0x07,[0x03]=0x09,[0x04]=0x0B,[0x05]=0x0A,
        [0x06]=0x1D,[0x07]=0x1B,[0x08]=0x06,[0x09]=0x19,[0x0A]=0x64,[0x0B]=0x05,
        [0x0C]=0x14,[0x0D]=0x1A,[0x0E]=0x08,[0x0F]=0x15,[0x10]=0x1C,[0x11]=0x17,
        [0x12]=0x1E,[0x13]=0x1F,[0x14]=0x20,[0x15]=0x21,[0x16]=0x23,[0x17]=0x22,
        [0x18]=0x2E,[0x19]=0x26,[0x1A]=0x24,[0x1B]=0x2D,[0x1C]=0x25,[0x1D]=0x27,
        [0x1E]=0x30,[0x1F]=0x12,[0x20]=0x18,[0x21]=0x2F,[0x22]=0x0C,[0x23]=0x13,
        [0x24]=0x28,[0x25]=0x0F,[0x26]=0x0D,[0x27]=0x34,[0x28]=0x0E,[0x29]=0x33,
        [0x2A]=0x31,[0x2B]=0x36,[0x2C]=0x38,[0x2D]=0x11,[0x2E]=0x10,[0x2F]=0x37,
        [0x30]=0x2B,[0x31]=0x2C,[0x32]=0x35,[0x33]=0x2A,[0x35]=0x29,
        [0x41]=0x63,[0x43]=0x55,[0x45]=0x57,[0x47]=0x53,[0x4B]=0x54,[0x4C]=0x58,[0x4E]=0x56,
        [0x52]=0x62,[0x53]=0x59,[0x54]=0x5A,[0x55]=0x5B,[0x56]=0x5C,[0x57]=0x5D,
        [0x58]=0x5E,[0x59]=0x5F,[0x5B]=0x60,[0x5C]=0x61,
        [0x60]=0x3E,[0x61]=0x3F,[0x62]=0x40,[0x63]=0x3C,[0x64]=0x41,[0x65]=0x42,
        [0x67]=0x44,[0x6D]=0x43,[0x6F]=0x45,[0x72]=0x49,[0x73]=0x4A,[0x74]=0x4B,
        [0x75]=0x4C,[0x76]=0x3D,[0x77]=0x4D,[0x78]=0x3B,[0x79]=0x4E,[0x7A]=0x3A,
        [0x7B]=0x50,[0x7C]=0x4F,[0x7D]=0x51,[0x7E]=0x52
    };
    return code < 128 ? map[code] : 0;
}

+ (uint8_t)physicalModifiersForFlags:(NSEventModifierFlags)flags {
    return ((flags & NSEventModifierFlagControl) ? 1 : 0)
        | ((flags & NSEventModifierFlagCommand) ? 1 : 0)
        | ((flags & NSEventModifierFlagShift) ? 2 : 0)
        | ((flags & NSEventModifierFlagOption) ? 4 : 0);
}

+ (NSData *)keyboardPayloadWithModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages {
    uint8_t report[9] = {modifiers, 0, 0, 0, 0, 0, 0, 0, 0};
    if (usages.count > 6) memset(report + 2, 1, 6);
    else for (NSUInteger i = 0; i < usages.count; i++) report[2 + i] = usages[i].unsignedCharValue;
    return HIDBytes(report, sizeof(report));
}

+ (BOOL)callbackDevice:(id)callbackDevice matchesDevice:(id)expectedDevice psm:(uint16_t)callbackPSM expectedPSM:(uint16_t)expectedPSM {
    return callbackDevice == expectedDevice && callbackPSM == expectedPSM;
}

- (instancetype)init {
    if ((self = [super init])) {
        _protocolMode = 1;
        _keyboardReport = [AniCeHIDProtocol keyboardPayloadWithModifiers:0 usages:@[]];
        const uint8_t neutralMouse[] = {0, 0, 0, 0, 0};
        _mouseReport = HIDBytes(neutralMouse, sizeof(neutralMouse));
    }
    return self;
}

- (NSData *)keyboardPacketWithModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages error:(NSString **)error {
    if (self.suspended) { if (error) *error = @"The phone suspended HID input."; return nil; }
    if (usages.count > 6) { if (error) *error = @"A keyboard report can hold at most six keys."; return nil; }
    for (NSNumber *usage in usages) {
        if (usage.unsignedIntegerValue == 0 || usage.unsignedIntegerValue > 0x65) {
            if (error) *error = @"The keyboard usage is outside the published descriptor.";
            return nil;
        }
    }
    NSData *payload = [AniCeHIDProtocol keyboardPayloadWithModifiers:modifiers usages:usages];
    const uint8_t prefix[] = {0xA1, 0x01};
    NSMutableData *packet = [HIDBytes(prefix, sizeof(prefix)) mutableCopy];
    [packet appendData:self.protocolMode ? payload : [payload subdataWithRange:NSMakeRange(0, 8)]];
    return packet;
}

- (NSData *)mousePacketWithButtons:(uint8_t)buttons deltaX:(NSInteger)x deltaY:(NSInteger)y wheel:(NSInteger)wheel error:(NSString **)error {
    if (self.suspended) { if (error) *error = @"The phone suspended HID input."; return nil; }
    if ((buttons & ~3) || x < -127 || x > 127 || y < -127 || y > 127 || wheel < -8 || wheel > 8) {
        if (error) *error = @"The mouse report contains a field outside its published bounds.";
        return nil;
    }
    if (!self.protocolMode && wheel != 0) {
        if (error) *error = @"Scrolling is unavailable while the phone uses boot protocol.";
        return nil;
    }
    uint8_t bytes[] = {buttons, (uint8_t)(int8_t)x, (uint8_t)(int8_t)y, 0, (uint8_t)(int8_t)wheel};
    NSData *payload = HIDBytes(bytes, sizeof(bytes));
    const uint8_t prefix[] = {0xA1, self.protocolMode ? 0x0A : 0x02};
    NSMutableData *packet = [HIDBytes(prefix, sizeof(prefix)) mutableCopy];
    [packet appendData:self.protocolMode ? payload : [payload subdataWithRange:NSMakeRange(0, 3)]];
    return packet;
}

- (NSData *)navigationPacketWithUsage:(uint16_t)usage pressed:(BOOL)pressed error:(NSString **)error {
    if (self.suspended) { if (error) *error = @"The phone suspended HID input."; return nil; }
    if (!self.protocolMode) { if (error) *error = @"Phone navigation buttons need report protocol."; return nil; }
    uint16_t bit = usage == 0x0224 ? 1 : usage == 0x0223 ? 4 : 0;
    if (!bit) { if (error) *error = @"This phone navigation usage is not supported."; return nil; }
    uint8_t packet[] = {0xA1, 0x02, (uint8_t)(pressed ? bit : 0), 0};
    return HIDBytes(packet, sizeof(packet));
}

- (NSArray<NSDictionary<NSString *, id> *> *)consumePacket:(NSData *)packet control:(BOOL)control {
    NSMutableArray<NSDictionary<NSString *, id> *> *responses = [NSMutableArray array];
    void (^reply)(uint8_t, BOOL) = ^(uint8_t status, BOOL onControl) {
        NSData *data = HIDBytes(&status, 1);
        [responses addObject:@{@"control": @(onControl), @"data": data}];
    };
    if (packet.length == 0 || packet.length > 64) {
        if (control) reply(0x04, YES);
        return responses;
    }
    const uint8_t *p = packet.bytes;
    uint8_t transaction = p[0] >> 4, parameter = p[0] & 0x0F;
    if (!control) {
        if (transaction == 0x0A && packet.length == 3 && (p[0] & 0x0F) == 2 && p[1] == 1) self.leds = p[2] & 0x1F;
        return responses;
    }
    switch (transaction) {
        case 0x0: // HANDSHAKE has no response.
            break;
        case 0x1: // HID_CONTROL
            if (packet.length != 1) { reply(0x04, YES); break; }
            if (parameter == 3) self.suspended = YES;
            else if (parameter == 4) self.suspended = NO;
            else if (parameter == 5) self.unplugRequested = YES;
            else if (parameter == 1 || parameter == 2) {
                self.protocolMode = 1; self.suspended = NO; self.unplugRequested = NO;
                self.keyboardReport = [AniCeHIDProtocol keyboardPayloadWithModifiers:0 usages:@[]];
                const uint8_t neutral[] = {0, 0, 0, 0, 0}; self.mouseReport = HIDBytes(neutral, sizeof(neutral));
                self.consumerControls = 0;
            }
            break;
        case 0x4: { // GET_REPORT
            BOOL sized = (parameter & 8) != 0;
            if ((parameter & 4) || packet.length != (sized ? 4U : 2U)) { reply(0x04, YES); break; }
            uint8_t type = parameter & 3, reportID = p[1];
            NSData *payload = nil;
            if (type == 1 && reportID == 1) payload = self.protocolMode ? self.keyboardReport : [self.keyboardReport subdataWithRange:NSMakeRange(0, 8)];
            else if (type == 1 && reportID == 2 && self.protocolMode) {
                uint8_t value[] = {(uint8_t)self.consumerControls, (uint8_t)(self.consumerControls >> 8)};
                payload = HIDBytes(value, sizeof(value));
            } else if (type == 1 && reportID == (self.protocolMode ? 10 : 2)) {
                payload = self.protocolMode ? self.mouseReport : [self.mouseReport subdataWithRange:NSMakeRange(0, 3)];
            } else if (type == 2 && reportID == 1) {
                uint8_t led = self.leds; payload = HIDBytes(&led, 1);
            } else { reply((type == 1 || type == 2) ? 0x02 : 0x03, YES); break; }
            NSMutableData *body = [HIDBytes(&reportID, 1) mutableCopy]; [body appendData:payload];
            if (sized) {
                NSUInteger limit = p[2] | ((NSUInteger)p[3] << 8);
                if (body.length > limit) body.length = limit;
            }
            uint8_t header = 0xA0 | type;
            NSMutableData *response = [HIDBytes(&header, 1) mutableCopy]; [response appendData:body];
            [responses addObject:@{@"control": @YES, @"data": response}];
            break;
        }
        case 0x5: // SET_REPORT
            if ((parameter & 3) != 2) reply(0x03, YES);
            else if (packet.length < 2 || (parameter & 0x0C)) reply(0x04, YES);
            else if (p[1] != 1) reply(0x02, YES);
            else if (packet.length != 3) reply(0x04, YES);
            else { self.leds = p[2] & 0x1F; reply(0x00, YES); }
            break;
        case 0x6: { // GET_PROTOCOL
            if (parameter || packet.length != 1) { reply(0x04, YES); break; }
            uint8_t response[] = {0xA0, (uint8_t)self.protocolMode};
            [responses addObject:@{@"control": @YES, @"data": HIDBytes(response, sizeof(response))}];
            break;
        }
        case 0x7: // SET_PROTOCOL
            if (parameter > 1 || packet.length != 1) reply(0x04, YES);
            else { self.protocolMode = parameter; reply(0x00, YES); }
            break;
        case 0xA: // DATA output reports need no handshake response.
            break;
        default:
            reply(0x03, YES);
            break;
    }
    return responses;
}

- (void)reset {
    self.protocolMode = 1; self.suspended = NO; self.unplugRequested = NO; self.leds = 0; self.consumerControls = 0;
    self.keyboardReport = [AniCeHIDProtocol keyboardPayloadWithModifiers:0 usages:@[]];
    const uint8_t neutral[] = {0, 0, 0, 0, 0}; self.mouseReport = HIDBytes(neutral, sizeof(neutral));
}
@end

@interface AniCeHIDTransportWorker : NSObject
@property(nonatomic, strong) NSThread *thread;
@property(nonatomic, strong) NSCondition *startup;
@property(nonatomic, strong) NSLock *jobLock;
@property(nonatomic, strong) NSMutableArray<dispatch_block_t> *jobs;
@property(nonatomic) NSUInteger pendingCount;
@property(nonatomic) BOOL started;
@property(atomic) BOOL stopping;
@property(nonatomic) BOOL executing;
- (BOOL)perform:(dispatch_block_t)work;
- (BOOL)performShutdown:(dispatch_block_t)work;
- (void)finish;
@end

@implementation AniCeHIDTransportWorker
- (instancetype)init {
    if ((self = [super init])) {
        _startup = [NSCondition new]; _jobLock = [NSLock new]; _jobs = [NSMutableArray array];
        [_startup lock];
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        _thread.name = @"aniCe Classic HID";
        _thread.qualityOfService = NSQualityOfServiceUserInitiated;
        [_thread start];
        while (!_started) [_startup wait];
        [_startup unlock];
    }
    return self;
}
- (void)run {
    @autoreleasepool {
        NSRunLoop *loop = NSRunLoop.currentRunLoop;
        NSPort *port = [NSMachPort port]; [loop addPort:port forMode:NSDefaultRunLoopMode];
        [self.startup lock]; self.started = YES; [self.startup signal]; [self.startup unlock];
        while (!self.stopping) [loop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
        [loop removePort:port forMode:NSDefaultRunLoopMode]; [port invalidate]; self.thread = nil;
    }
}
- (BOOL)schedule:(dispatch_block_t)work unlimited:(BOOL)unlimited {
    NSThread *thread = self.thread;
    if (!thread || self.stopping) return NO;
    [self.jobLock lock];
    if ((!unlimited && self.pendingCount >= 256) || self.stopping) { [self.jobLock unlock]; return NO; }
    self.pendingCount++;
    [self.jobLock unlock];
    [self performSelector:@selector(execute:) onThread:thread withObject:[work copy] waitUntilDone:NO];
    return YES;
}
- (BOOL)perform:(dispatch_block_t)work { return [self schedule:work unlimited:NO]; }
- (BOOL)performShutdown:(dispatch_block_t)work { return [self schedule:work unlimited:YES]; }
- (void)execute:(dispatch_block_t)work {
    [self.jobs addObject:work];
    if (self.executing) return; // SDK waits pump this run loop recursively; state changes stay serial.
    self.executing = YES;
    while (self.jobs.count && !self.stopping) {
        dispatch_block_t next = self.jobs.firstObject; [self.jobs removeObjectAtIndex:0];
        @autoreleasepool { next(); }
        [self.jobLock lock]; if (self.pendingCount) self.pendingCount--; [self.jobLock unlock];
    }
    self.executing = NO;
}
- (void)finish { self.stopping = YES; }
@end

@interface AniCeHIDSession : NSObject <IOBluetoothL2CAPChannelDelegate>
@property(nonatomic, strong) AniCeHIDProtocol *protocol;
@property(nonatomic, strong, nullable) IOBluetoothDevice *device;
@property(nonatomic, strong, nullable) IOBluetoothSDPServiceRecord *service;
@property(nonatomic, strong, nullable) IOBluetoothL2CAPChannel *control;
@property(nonatomic, strong, nullable) IOBluetoothL2CAPChannel *interrupt;
@property(nonatomic, copy, nullable) AniCeHIDStateChanged stateChanged;
@property(nonatomic, copy, nullable) NSString *lastError;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL authenticated;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL connecting;
@property(nonatomic) BOOL closing;
@property(nonatomic) BOOL completion;
@property(nonatomic) IOReturn completionStatus;
@property(nonatomic) BluetoothL2CAPPSM openingPSM;
@property(nonatomic) NSTimeInterval callbackTimeout;
@property(nonatomic, copy, nullable) BOOL (^cancellationRequested)(void);
- (BOOL)connect:(NSString *)address error:(NSString **)error;
- (BOOL)sendKeyboardModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages error:(NSString **)error;
- (BOOL)sendMouseButtons:(uint8_t)buttons deltaX:(NSInteger)x deltaY:(NSInteger)y wheel:(NSInteger)wheel error:(NSString **)error;
- (BOOL)sendNavigationUsage:(uint16_t)usage pressed:(BOOL)pressed error:(NSString **)error;
- (void)disconnect;
- (void)stop;
@end

@implementation AniCeHIDSession
- (instancetype)init {
    if ((self = [super init])) { _protocol = [AniCeHIDProtocol new]; _callbackTimeout = 15; }
    return self;
}
- (BOOL)fail:(NSString *)message error:(NSString **)error {
    self.lastError = message;
    if (error) *error = message;
    return NO;
}
- (void)publishState:(NSString *)message {
    AniCeHIDStateChanged callback = self.stateChanged;
    BOOL ready = self.ready, suspended = self.protocol.suspended, report = self.protocol.protocolMode == 1;
    uint64_t generation = self.generation;
    if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(generation, ready, suspended, report, message); });
}
- (BOOL)waitForCompletion:(NSString *)stage error:(NSString **)error {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + self.callbackTimeout;
    while (!self.completion && NSProcessInfo.processInfo.systemUptime < deadline) {
        if (self.cancellationRequested && self.cancellationRequested())
            return [self fail:@"Bluetooth HID connection was cancelled." error:error];
        HIDPump(0.01);
    }
    if (self.cancellationRequested && self.cancellationRequested())
        return [self fail:@"Bluetooth HID connection was cancelled." error:error];
    if (!self.completion) return [self fail:[stage stringByAppendingString:@" timed out waiting for the Bluetooth callback."] error:error];
    if (self.completionStatus != kIOReturnSuccess) return [self fail:HIDIOError(stage, self.completionStatus) error:error];
    return YES;
}
- (BOOL)openPSM:(BluetoothL2CAPPSM)psm error:(NSString **)error {
    IOBluetoothL2CAPChannel *channel = nil;
    NSString *stage = [NSString stringWithFormat:@"Opening the HID %@ channel (PSM 0x%04X)", psm == 0x11 ? @"control" : @"interrupt", psm];
    self.openingPSM = psm; self.completion = NO;
    IOReturn result = [self.device openL2CAPChannelAsync:&channel withPSM:psm delegate:self];
    // Explicit registration starts the modern public channel bridge and its callback stream.
    if (result == kIOReturnSuccess && channel && channel.PSM == psm)
        result = [channel setDelegate:self];
    BOOL matched = channel && channel.PSM == psm && channel.device == self.device;
    BOOL opened = result == kIOReturnSuccess && matched && [self waitForCompletion:stage error:error];
    if (opened && (psm == 0x11 ? self.control : self.interrupt) != channel) {
        opened = NO;
        [self fail:@"The Bluetooth callback did not belong to the opened HID channel." error:error];
    }
    self.openingPSM = 0;
    if (!opened) {
        IOBluetoothL2CAPChannel *adopted = psm == 0x11 ? self.control : self.interrupt;
        [channel setDelegate:nil]; [channel closeChannel];
        if (adopted && adopted != channel) { [adopted setDelegate:nil]; [adopted closeChannel]; }
        if (psm == 0x11) self.control = nil; else self.interrupt = nil;
        if (result != kIOReturnSuccess) return [self fail:HIDIOError(stage, result) error:error];
        if (channel && !matched) return [self fail:@"The Bluetooth channel device or PSM did not match the request." error:error];
        if (error && !*error) *error = self.lastError ?: [stage stringByAppendingString:@" failed."];
        self.lastError = error ? *error : self.lastError;
        return NO;
    }
    if (psm == 0x11) self.control = channel; else self.interrupt = channel;
    return YES;
}
- (BOOL)authenticatedLinkWithError:(NSString **)error {
    if (!self.authenticated)
        return [self fail:@"Bluetooth authentication has not completed for this connection." error:error];
    if (!self.device || !self.device.isPaired || !self.device.isConnected)
        return [self fail:@"The selected Bluetooth device is no longer paired or connected." error:error];
    return YES;
}
- (BOOL)connect:(NSString *)address error:(NSString **)error {
    [self disconnect];
    self.lastError = nil; self.connecting = YES;
    if (self.cancellationRequested && self.cancellationRequested()) {
        self.connecting = NO;
        return [self fail:@"Bluetooth HID connection was cancelled." error:error];
    }
    [self.protocol reset];
    NSString *normalized = [AniCeHIDProtocol normalizedAddress:address];
    if (!normalized) { self.connecting = NO; return [self fail:@"The saved Bluetooth address is invalid." error:error]; }
    IOBluetoothHostController *host = IOBluetoothHostController.defaultController;
    if (!host || host.powerState != kBluetoothHCIPowerStateON) {
        self.connecting = NO;
        return [self fail:@"Bluetooth is unavailable. Check Bluetooth in System Settings, then try again." error:error];
    }
    self.device = [IOBluetoothDevice deviceWithAddressString:normalized];
    if (!self.device || !self.device.isPaired) {
        self.connecting = NO;
        return [self fail:@"This phone is not paired in macOS Bluetooth Settings. Pair it there, then return to Keyboard & Trackpad." error:error];
    }
    for (NSUInteger attempt = 0; attempt < 3 && !self.service; attempt++) {
        self.service = [IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:HIDServiceDictionary()];
        if (!self.service) HIDPump(0.1);
    }
    if (!self.service) {
        self.connecting = NO;
        return [self fail:@"The Mac could not publish its Bluetooth HID service. Check Bluetooth access and try again." error:error];
    }
    NSString *serviceError = HIDServiceValidationError(self.service);
    if (serviceError) { self.connecting = NO; [self stop]; return [self fail:serviceError error:error]; }
    if (!self.device.isConnected) {
        self.completion = NO; self.openingPSM = 0;
        IOReturn result = [self.device openConnection:self withPageTimeout:0x2000 authenticationRequired:YES];
        if (result != kIOReturnSuccess) {
            self.connecting = NO;
            return [self fail:HIDIOError(@"Authenticating the paired Bluetooth link", result) error:error];
        }
        if (![self waitForCompletion:@"Authenticating the paired Bluetooth link" error:error]) { self.connecting = NO; [self disconnect]; return NO; }
    } else {
        // The SDK performs this authentication call synchronously; it is isolated on this worker.
        IOReturn result = [self.device requestAuthentication];
        if (result != kIOReturnSuccess) {
            self.connecting = NO;
            return [self fail:HIDIOError(@"Authenticating the existing Bluetooth link", result) error:error];
        }
    }
    self.authenticated = YES;
    // Match aniKey: macOS owns encryption; input requires successful authentication of this link.
    if (![self authenticatedLinkWithError:error] || ![self openPSM:0x0011 error:error] || ![self openPSM:0x0013 error:error]) {
        self.connecting = NO; [self disconnect]; return NO;
    }
    self.ready = YES; self.connecting = NO;
    HIDPump(0.25); // Allow host protocol negotiation before accepting user input.
    if (self.cancellationRequested && self.cancellationRequested()) {
        [self disconnect];
        return [self fail:@"Bluetooth HID connection was cancelled." error:error];
    }
    if (!self.ready || self.protocol.suspended || ![self authenticatedLinkWithError:error]) {
        self.connecting = NO; [self disconnect];
        if (error && !*error) *error = self.lastError ?: @"Bluetooth HID did not become ready.";
        return NO;
    }
    if (![self sendKeyboardModifiers:0 usages:@[] error:error]) { [self disconnect]; return NO; }
    [self publishState:nil];
    return YES;
}
- (BOOL)writePacket:(NSData *)packet control:(BOOL)control error:(NSString **)error {
    if (packet.length == 0 || packet.length > 64) return [self fail:@"The HID packet length is invalid." error:error];
    if (![self authenticatedLinkWithError:error]) { self.ready = NO; return NO; }
    IOBluetoothL2CAPChannel *channel = control ? self.control : self.interrupt;
    if (!channel || channel.device != self.device || channel.PSM != (control ? 0x0011 : 0x0013)) {
        self.ready = NO;
        return [self fail:@"The HID channel no longer matches the selected device." error:error];
    }
    NSMutableData *buffer = [packet mutableCopy];
    IOReturn result = [channel writeSync:buffer.mutableBytes length:(UInt16)buffer.length];
    if (result != kIOReturnSuccess) {
        self.ready = NO;
        return [self fail:HIDIOError(control ? @"Writing the HID control packet" : @"Writing the HID input report", result) error:error];
    }
    return YES;
}
- (BOOL)sendKeyboardModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages error:(NSString **)error {
    if (!self.ready) return [self fail:self.lastError ?: @"Connect to the selected phone before sending input." error:error];
    NSString *protocolError = nil;
    NSData *packet = [self.protocol keyboardPacketWithModifiers:modifiers usages:usages error:&protocolError];
    if (!packet) return [self fail:protocolError ?: @"The keyboard report is invalid." error:error];
    if (![self writePacket:packet control:NO error:error]) return NO;
    self.protocol.keyboardReport = [AniCeHIDProtocol keyboardPayloadWithModifiers:modifiers usages:usages];
    return YES;
}
- (BOOL)sendMouseButtons:(uint8_t)buttons deltaX:(NSInteger)x deltaY:(NSInteger)y wheel:(NSInteger)wheel error:(NSString **)error {
    if (!self.ready) return [self fail:self.lastError ?: @"Connect to the selected phone before sending input." error:error];
    NSString *protocolError = nil;
    NSData *packet = [self.protocol mousePacketWithButtons:buttons deltaX:x deltaY:y wheel:wheel error:&protocolError];
    if (!packet) return [self fail:protocolError ?: @"The mouse report is invalid." error:error];
    if (![self writePacket:packet control:NO error:error]) return NO;
    uint8_t mouse[] = {buttons, 0, 0, 0, 0};
    self.protocol.mouseReport = HIDBytes(mouse, sizeof(mouse));
    return YES;
}
- (BOOL)sendNavigationUsage:(uint16_t)usage pressed:(BOOL)pressed error:(NSString **)error {
    if (!self.ready) return [self fail:self.lastError ?: @"Connect to the selected phone before sending input." error:error];
    NSString *protocolError = nil;
    NSData *packet = [self.protocol navigationPacketWithUsage:usage pressed:pressed error:&protocolError];
    if (!packet) return [self fail:protocolError ?: @"The navigation report is invalid." error:error];
    if (![self writePacket:packet control:NO error:error]) return NO;
    self.protocol.consumerControls = pressed ? (usage == 0x0224 ? 1 : 4) : 0;
    return YES;
}
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (device == self.device && self.connecting && self.openingPSM == 0) {
        self.completionStatus = status; self.completion = YES;
    }
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)channel status:(IOReturn)status {
    if (![AniCeHIDProtocol callbackDevice:channel.device matchesDevice:self.device psm:channel.PSM expectedPSM:self.openingPSM] || !self.connecting) return;
    self.completionStatus = status; self.completion = YES;
    if (status == kIOReturnSuccess) {
        if (channel.PSM == 0x0011) self.control = channel;
        else if (channel.PSM == 0x0013) self.interrupt = channel;
    }
}
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)channel {
    if (self.closing || (channel != self.control && channel != self.interrupt)) return;
    self.ready = NO;
    self.lastError = [NSString stringWithFormat:@"Bluetooth HID channel PSM 0x%04X closed. Reconnect explicitly to try again.", channel.PSM];
    self.completionStatus = kIOReturnNotOpen; self.completion = YES;
    if (channel == self.control) self.control = nil; else self.interrupt = nil;
    NSString *message = self.lastError;
    [self disconnect];
    [self publishState:message];
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)pointer length:(size_t)length {
    if (!self.device || channel.device != self.device || (channel.PSM != 0x0011 && channel.PSM != 0x0013)) return;
    if (self.connecting && channel.PSM == self.openingPSM) {
        if (channel.PSM == 0x0011 && !self.control) self.control = channel;
        else if (channel.PSM == 0x0013 && !self.interrupt) self.interrupt = channel;
    }
    BOOL control = channel == self.control;
    if (!control && channel != self.interrupt) return;
    BOOL wasSuspended = self.protocol.suspended;
    NSData *packet = HIDBytes(pointer, MIN(length, (size_t)65));
    for (NSDictionary<NSString *, id> *response in [self.protocol consumePacket:packet control:control]) {
        NSString *ignored = nil;
        if (![self writePacket:response[@"data"] control:[response[@"control"] boolValue] error:&ignored]) {
            [self publishState:ignored]; [self disconnect]; return;
        }
    }
    if (wasSuspended && !self.protocol.suspended && self.ready) {
        NSString *error = nil;
        if (![self releaseHeldReportsWithError:&error]) {
            [self disconnect]; [self publishState:error]; return;
        }
    }
    if (self.protocol.unplugRequested) {
        self.lastError = @"The phone ended the HID bond. Reconnect manually to control it again.";
        [self stop]; [self publishState:self.lastError];
    } else if (self.protocol.suspended) {
        [self publishState:@"The phone suspended keyboard and trackpad input."];
    } else if (control) {
        [self publishState:nil];
    }
}
- (BOOL)releaseHeldReportsWithError:(NSString **)error {
    BOOL success = YES;
    if (memcmp(self.protocol.keyboardReport.bytes, (uint8_t[9]){0}, 9) != 0 &&
        ![self sendKeyboardModifiers:0 usages:@[] error:error]) success = NO;
    if (self.protocol.consumerControls) {
        const uint8_t release[] = {0xA1, 0x02, 0, 0};
        if ([self writePacket:HIDBytes(release, sizeof(release)) control:NO error:error])
            self.protocol.consumerControls = 0;
        else success = NO;
    }
    if (self.protocol.mouseReport.length && ((const uint8_t *)self.protocol.mouseReport.bytes)[0] &&
        ![self sendMouseButtons:0 deltaX:0 deltaY:0 wheel:0 error:error]) success = NO;
    return success;
}
- (void)disconnect {
    self.closing = YES;
    if (self.ready && !self.protocol.suspended) {
        NSString *ignored = nil;
        [self releaseHeldReportsWithError:&ignored];
    }
    self.ready = NO; self.authenticated = NO; self.connecting = NO; self.openingPSM = 0; self.completion = NO;
    [self.control setDelegate:nil]; [self.interrupt setDelegate:nil];
    [self.control closeChannel]; [self.interrupt closeChannel];
    self.control = nil; self.interrupt = nil; self.device = nil;
    self.closing = NO;
    [self publishState:nil];
}
- (void)stop {
    [self disconnect];
    [self.service removeServiceRecord]; self.service = nil;
}
@end

@interface AniCeHIDAdapter ()
@property(nonatomic, strong) AniCeHIDTransportWorker *worker;
@property(nonatomic, strong, nullable) AniCeHIDSession *session;
@property(nonatomic) BOOL shutDown;
@property(atomic) BOOL connectionCancellationRequested;
@end

@implementation AniCeHIDAdapter
- (instancetype)init {
    if ((self = [super init])) _worker = [AniCeHIDTransportWorker new];
    return self;
}
- (AniCeHIDSession *)sessionOnWorker {
    if (!self.session) {
        self.session = [AniCeHIDSession new];
        __weak typeof(self) weakSelf = self;
        self.session.cancellationRequested = ^BOOL{ return weakSelf.connectionCancellationRequested; };
        self.session.stateChanged = ^(uint64_t generation, BOOL ready, BOOL suspended, BOOL reportProtocol, NSString *message) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            AniCeHIDStateChanged callback = strongSelf.stateChanged;
            if (callback) callback(generation, ready, suspended, reportProtocol, message);
        };
    }
    return self.session;
}
- (void)enumeratePairedDevices:(AniCeHIDDevicesCompletion)completion {
    if (![self.worker perform:^{
        NSMutableArray *devices = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (IOBluetoothDevice *device in IOBluetoothDevice.pairedDevices ?: @[]) {
            if (!device.isPaired) continue;
            NSString *address = [AniCeHIDProtocol normalizedAddress:device.addressString ?: @""];
            if (!address.length || [seen containsObject:address]) continue;
            [seen addObject:address];
            NSString *name = device.nameOrAddress ?: @"";
            [devices addObject:@{@"address": address, @"name": name}];
        }
        NSArray *snapshot = [devices copy];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(snapshot); });
    }]) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[]); });
}
- (BOOL)connectAddress:(NSString *)address generation:(uint64_t)generation completion:(AniCeHIDCompletion)completion {
    NSString *normalized = [AniCeHIDProtocol normalizedAddress:address];
    if (!normalized) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"The saved Bluetooth address is invalid."); }); return YES; }
    self.connectionCancellationRequested = NO;
    if (![self.worker perform:^{
        NSString *error = nil;
        [self sessionOnWorker].generation = generation;
        BOOL success = [[self sessionOnWorker] connect:normalized error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, error); });
    }]) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"The Bluetooth worker is shutting down or busy."); }); return NO; }
    return YES;
}
- (BOOL)sendKeyboardModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages completion:(AniCeHIDCompletion)completion {
    NSArray *snapshot = [usages copy];
    if (![self.worker perform:^{
        NSString *error = nil;
        BOOL success = [[self sessionOnWorker] sendKeyboardModifiers:modifiers usages:snapshot error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, error); });
    }]) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"The Bluetooth input queue is full."); }); return NO; }
    return YES;
}
- (BOOL)sendMouseButtons:(uint8_t)buttons deltaX:(NSInteger)x deltaY:(NSInteger)y wheel:(NSInteger)wheel completion:(AniCeHIDCompletion)completion {
    if (![self.worker perform:^{
        NSString *error = nil;
        BOOL success = [[self sessionOnWorker] sendMouseButtons:buttons deltaX:x deltaY:y wheel:wheel error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, error); });
    }]) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"The Bluetooth input queue is full."); }); return NO; }
    return YES;
}
- (BOOL)sendNavigationUsage:(uint16_t)usage pressed:(BOOL)pressed completion:(AniCeHIDCompletion)completion {
    if (![self.worker perform:^{
        NSString *error = nil;
        BOOL success = [[self sessionOnWorker] sendNavigationUsage:usage pressed:pressed error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(success, error); });
    }]) { dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, @"The Bluetooth input queue is full."); }); return NO; }
    return YES;
}
- (BOOL)disconnectWithCompletion:(dispatch_block_t)completion {
    self.connectionCancellationRequested = YES;
    if (![self.worker performShutdown:^{
        [self.session disconnect];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    }]) { if (completion) dispatch_async(dispatch_get_main_queue(), completion); return NO; }
    return YES;
}
- (void)shutdown {
    if (self.shutDown) return;
    self.shutDown = YES;
    self.connectionCancellationRequested = YES;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    BOOL scheduled = [self.worker performShutdown:^{
        [self.session stop]; self.session = nil;
        [self.worker finish];
        dispatch_semaphore_signal(finished);
    }];
    if (scheduled)
        dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 500));
}
@end
