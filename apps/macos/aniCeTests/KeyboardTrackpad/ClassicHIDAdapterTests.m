// SPDX-License-Identifier: GPL-3.0-or-later
// Tests the packaged adapter's HID descriptor, exact report bytes, SDP and channel callback guards.
#import <XCTest/XCTest.h>
#import <IOBluetooth/IOBluetooth.h>
#import "../../aniCe/Features/KeyboardTrackpad/ClassicHIDAdapter.h"

static NSData *HIDParseHex(NSString *hex) {
    NSMutableData *result = [NSMutableData data];
    for (NSString *part in [hex componentsSeparatedByString:@" "]) {
        unsigned value = 0;
        [[NSScanner scannerWithString:part] scanHexInt:&value];
        uint8_t byte = (uint8_t)value;
        [result appendBytes:&byte length:1];
    }
    return result;
}

static NSDictionary *HIDVectors(void) {
    NSURL *url = [[NSBundle bundleForClass:NSClassFromString(@"ClassicHIDAdapterTests")]
        URLForResource:@"hid-vectors" withExtension:@"json"];
    NSData *data = [NSData dataWithContentsOfURL:url];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

// Independent descriptor sizing: input lengths include constant fields but exclude report IDs.
static NSDictionary<NSNumber *, NSNumber *> *HIDInputBits(NSData *descriptor) {
    const uint8_t *bytes = descriptor.bytes;
    NSUInteger offset = 0;
    uint32_t size = 0, count = 0, reportID = 0;
    NSMutableDictionary *bits = [NSMutableDictionary dictionary];
    while (offset < descriptor.length) {
        uint8_t header = bytes[offset++];
        if (header == 0xFE || header == 0xA4 || header == 0xB4) return nil;
        unsigned length = (header & 3) == 3 ? 4 : header & 3;
        if (offset + length > descriptor.length) return nil;
        uint32_t value = 0;
        for (unsigned i = 0; i < length; i++) value |= (uint32_t)bytes[offset + i] << (8 * i);
        offset += length;
        switch (header & 0xFC) {
            case 0x74: size = value; break;
            case 0x94: count = value; break;
            case 0x84: reportID = value; break;
            case 0x80: bits[@(reportID)] = @([bits[@(reportID)] unsignedIntValue] + size * count); break;
        }
    }
    return bits;
}

@interface NSObject (AniCeHIDSessionTestAccess)
- (void)setDevice:(IOBluetoothDevice *)device;
- (void)setControl:(IOBluetoothL2CAPChannel *)channel;
- (void)setInterrupt:(IOBluetoothL2CAPChannel *)channel;
- (void)setConnecting:(BOOL)connecting;
- (void)setReady:(BOOL)ready;
- (void)setAuthenticated:(BOOL)authenticated;
- (void)disconnect;
- (void)setOpeningPSM:(BluetoothL2CAPPSM)psm;
- (void)setCallbackTimeout:(NSTimeInterval)timeout;
- (IOBluetoothL2CAPChannel *)control;
- (BOOL)openPSM:(BluetoothL2CAPPSM)psm error:(NSString **)error;
- (BOOL)authenticatedLinkWithError:(NSString **)error;
- (void)setCancellationRequested:(BOOL (^)(void))check;
- (BOOL)waitForCompletion:(NSString *)stage error:(NSString **)error;
- (BOOL)sendKeyboardModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages error:(NSString **)error;
- (BOOL)sendMouseButtons:(uint8_t)buttons deltaX:(NSInteger)x deltaY:(NSInteger)y wheel:(NSInteger)wheel error:(NSString **)error;
- (BOOL)sendNavigationUsage:(uint16_t)usage pressed:(BOOL)pressed error:(NSString **)error;
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)data length:(size_t)length;
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)channel status:(IOReturn)status;
@end

@interface HIDMockChannel : NSObject
@property(nonatomic) BluetoothL2CAPPSM PSM;
@property(nonatomic, strong) IOBluetoothDevice *device;
@property(nonatomic, strong) id retainedDelegate;
@property(nonatomic) NSUInteger delegateRegistrations;
@property(nonatomic) NSUInteger closeCount;
@property(nonatomic) IOReturn delegateStatus;
@property(nonatomic) BOOL completeOnDelegate;
@property(nonatomic) IOReturn openStatus;
@property(nonatomic, strong) NSMutableArray<NSData *> *packets;
- (IOReturn)setDelegate:(id)delegate;
- (IOReturn)closeChannel;
@end

@implementation HIDMockChannel
- (IOReturn)writeSync:(void *)data length:(UInt16)length {
    if (!self.packets) self.packets = [NSMutableArray array];
    [self.packets addObject:[NSData dataWithBytes:data length:length]];
    return kIOReturnSuccess;
}
- (IOReturn)setDelegate:(id)delegate {
    self.retainedDelegate = delegate;
    if (delegate) {
        self.delegateRegistrations++;
        if (self.completeOnDelegate)
            [delegate l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)self status:self.openStatus];
    }
    return self.delegateStatus;
}
- (IOReturn)closeChannel { self.closeCount++; return kIOReturnSuccess; }
@end

@interface HIDMockOpenDevice : NSObject
@property(nonatomic, strong) HIDMockChannel *channel;
@property(nonatomic, strong) HIDMockChannel *callbackChannel;
@property(nonatomic) IOReturn openResult;
@property(nonatomic) BOOL omitReturnedChannel;
@property(nonatomic) BOOL emitEarlyCallback;
@property(nonatomic) BOOL emitCallback;
@property(nonatomic) BluetoothL2CAPPSM returnedPSM;
@property(nonatomic) IOReturn callbackStatus;
- (IOReturn)openL2CAPChannelAsync:(IOBluetoothL2CAPChannel **)channel
                         withPSM:(BluetoothL2CAPPSM)psm
                         delegate:(id)delegate;
@end

@implementation HIDMockOpenDevice
- (IOReturn)openL2CAPChannelAsync:(IOBluetoothL2CAPChannel **)channel
                         withPSM:(BluetoothL2CAPPSM)psm
                         delegate:(id)delegate {
    self.channel.PSM = self.returnedPSM ?: psm;
    self.channel.device = (IOBluetoothDevice *)self;
    self.channel.completeOnDelegate = self.emitCallback;
    self.channel.openStatus = self.callbackStatus;
    self.callbackChannel = self.callbackChannel ?: self.channel;
    if (self.emitEarlyCallback)
        [delegate l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)self.callbackChannel status:self.callbackStatus];
    *channel = self.omitReturnedChannel ? nil : (IOBluetoothL2CAPChannel *)self.channel;
    return self.openResult;
}
@end

@interface HIDMockSecurityDevice : NSObject
@property(nonatomic) BOOL paired;
@property(nonatomic) BOOL connected;
@property(nonatomic) BluetoothHCIEncryptionMode encryptionMode;
@property(nonatomic) NSUInteger encryptionReadCount;
- (BOOL)isPaired;
- (BOOL)isConnected;
- (BluetoothHCIEncryptionMode)getEncryptionMode;
@end

@implementation HIDMockSecurityDevice
- (BOOL)isPaired { return self.paired; }
- (BOOL)isConnected { return self.connected; }
- (BluetoothHCIEncryptionMode)getEncryptionMode {
    self.encryptionReadCount++;
    return self.encryptionMode;
}
@end

@interface ClassicHIDAdapterTests : XCTestCase
@end

@implementation ClassicHIDAdapterTests

- (void)testKeyboardReportsCoverTheCachedCompositeDescriptor {
    NSDictionary *vectors = HIDVectors();
    NSData *cached = HIDParseHex(vectors[@"cachedCompositeDescriptorHex"]);
    XCTAssertEqual(cached.length, 190U);
    NSDictionary *cachedBits = HIDInputBits(cached);
    XCTAssertEqualObjects(cachedBits, (@{@1: @72, @2: @16, @10: @40}));
    NSDictionary *publishedBits = HIDInputBits([AniCeHIDProtocol reportDescriptor]);
    XCTAssertEqualObjects(publishedBits, cachedBits);
    AniCeHIDProtocol *protocol = [AniCeHIDProtocol new];
    NSString *error = nil;
    NSArray<NSData *> *packets = @[
        [protocol keyboardPacketWithModifiers:2 usages:@[@4] error:&error],
        [protocol keyboardPacketWithModifiers:0 usages:@[] error:&error]
    ];
    XCTAssertEqual(packets.count, 2U);
    for (NSData *packet in packets) {
        XCTAssertNil(error);
        XCTAssertEqual(packet.length - 2, [cachedBits[@1] unsignedIntValue] / 8);
        XCTAssertEqual(((const uint8_t *)packet.bytes)[packet.length - 1], 0);
    }
    [protocol consumePacket:HIDParseHex(@"70") control:YES];
    XCTAssertEqualObjects([protocol keyboardPacketWithModifiers:2 usages:@[@4] error:&error],
                          HIDParseHex(vectors[@"reports"][@"bootKeyboardA"]));
    XCTAssertEqualObjects([protocol keyboardPacketWithModifiers:0 usages:@[] error:&error],
                          HIDParseHex(vectors[@"reports"][@"bootKeyboardRelease"]));
    XCTAssertEqual([[protocol consumePacket:HIDParseHex(@"41 01") control:YES].firstObject[@"data"] length], 10U);
    [protocol consumePacket:HIDParseHex(@"71") control:YES];
    XCTAssertEqual([[protocol consumePacket:HIDParseHex(@"41 01") control:YES].firstObject[@"data"] length], 11U);
}

- (void)testDescriptorAndExactReportFixtures {
    NSDictionary *vectors = HIDVectors();
    XCTAssertNotNil(vectors);
    NSData *descriptor = [AniCeHIDProtocol reportDescriptor];
    XCTAssertEqualObjects(descriptor, HIDParseHex(vectors[@"descriptorHex"]));

    AniCeHIDProtocol *protocol = [AniCeHIDProtocol new];
    NSString *error = nil;
    NSData *keyboard = [protocol keyboardPacketWithModifiers:2 usages:@[@4] error:&error];
    XCTAssertNil(error);
    XCTAssertEqualObjects(keyboard, HIDParseHex(vectors[@"reports"][@"keyboardA"]));
    XCTAssertEqualObjects([protocol keyboardPacketWithModifiers:0 usages:@[] error:&error],
                          HIDParseHex(vectors[@"reports"][@"keyboardRelease"]));

    NSData *mouse = [protocol mousePacketWithButtons:1 deltaX:0 deltaY:0 wheel:0 error:&error];
    XCTAssertEqualObjects(mouse, HIDParseHex(vectors[@"reports"][@"mouseLeftPress"]));
    XCTAssertEqualObjects([protocol mousePacketWithButtons:0 deltaX:0 deltaY:0 wheel:-2 error:&error],
                          HIDParseHex(vectors[@"reports"][@"mouseWheelMinusTwo"]));
    XCTAssertEqualObjects([protocol navigationPacketWithUsage:0x0224 pressed:YES error:&error],
                          HIDParseHex(vectors[@"reports"][@"consumerBack"]));
    XCTAssertEqualObjects([protocol navigationPacketWithUsage:0x0223 pressed:YES error:&error],
                          HIDParseHex(vectors[@"reports"][@"consumerHome"]));
    XCTAssertEqualObjects([protocol navigationPacketWithUsage:0x0224 pressed:NO error:&error],
                          HIDParseHex(vectors[@"reports"][@"consumerRelease"]));
    NSArray *modifiers = @[@0, @8, @8, @8, @0];
    NSArray *usages = @[@[], @[], @[@0x2B], @[], @[]];
    NSArray *recents = vectors[@"recents"];
    XCTAssertEqual(recents.count, 5U);
    for (NSUInteger i = 0; i < recents.count; i++)
        XCTAssertEqualObjects([protocol keyboardPacketWithModifiers:[modifiers[i] unsignedCharValue] usages:usages[i] error:&error],
                              HIDParseHex(recents[i]));

    NSArray *back = [protocol consumePacket:HIDParseHex(@"70") control:YES];
    XCTAssertEqualObjects(back.firstObject[@"data"], [NSData dataWithBytes:(uint8_t[]){0} length:1]);
    XCTAssertEqual(protocol.protocolMode, 0U);
    XCTAssertEqualObjects([protocol mousePacketWithButtons:1 deltaX:5 deltaY:-10 wheel:0 error:&error],
                          HIDParseHex(vectors[@"reports"][@"bootMouse"]));
    XCTAssertNil([protocol mousePacketWithButtons:0 deltaX:0 deltaY:0 wheel:1 error:&error]);
    XCTAssertTrue([error containsString:@"boot protocol"]);
}

- (void)testDescriptorSizesAndSdpEndpointsMatchThePublishedContract {
    NSData *descriptor = [AniCeHIDProtocol reportDescriptor];
    const uint8_t *bytes = descriptor.bytes;
    NSUInteger index = 0;
    unsigned reportID = 0, reportSize = 0, reportCount = 0, collectionDepth = 0;
    unsigned sizes[11][3] = {{0}};
    while (index < descriptor.length) {
        uint8_t header = bytes[index++];
        XCTAssertNotEqual(header, 0xFE);
        unsigned length = header & 3;
        if (length == 3) length = 4;
        XCTAssertLessThanOrEqual(index + length, descriptor.length);
        uint32_t value = 0;
        for (unsigned i = 0; i < length; i++) value |= (uint32_t)bytes[index + i] << (8 * i);
        index += length;
        unsigned type = (header >> 2) & 3, tag = header >> 4;
        if (type == 1) {
            if (tag == 7) reportSize = value;
            if (tag == 8) reportID = value;
            if (tag == 9) reportCount = value;
        } else if (type == 0) {
            if (tag == 10) collectionDepth++;
            else if (tag == 12) { XCTAssertGreaterThan(collectionDepth, 0U); collectionDepth--; }
            else if (tag == 8 || tag == 9 || tag == 11) {
                XCTAssertTrue(reportID == 1 || reportID == 2 || reportID == 10);
                unsigned direction = tag == 8 ? 0 : tag == 9 ? 1 : 2;
                sizes[reportID][direction] += reportSize * reportCount;
            }
        }
    }
    XCTAssertEqual(collectionDepth, 0U);
    XCTAssertEqual(sizes[1][0], 72U);
    XCTAssertEqual(sizes[1][1], 8U);
    XCTAssertEqual(sizes[2][0], 16U);
    XCTAssertEqual(sizes[10][0], 40U);

    NSDictionary *service = [AniCeHIDProtocol serviceRecordDictionary];
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    [service enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if ([key isEqualToString:@"LocalAttributes"]) return;
        unsigned attributeID = 0;
        [[NSScanner scannerWithString:[key substringToIndex:4]] scanHexInt:&attributeID];
        IOBluetoothSDPDataElement *element = [IOBluetoothSDPDataElement withElementValue:value];
        XCTAssertNotNil(element);
        if (element) attributes[@(attributeID)] = element;
    }];
    IOBluetoothSDPServiceRecord *record = [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
    XCTAssertNotNil(record);
    XCTAssertNil([AniCeHIDProtocol serviceRecordValidationError:record]);
    XCTAssertEqualObjects([[[record getAttributeDataElement:0x0001] getArrayValue][0] getUUIDValue],
                          [IOBluetoothSDPUUID uuid16:0x1124]);

    BluetoothL2CAPPSM controlPSM = 0;
    XCTAssertEqual([record getL2CAPPSM:&controlPSM], kIOReturnSuccess);
    XCTAssertEqual(controlPSM, 0x0011);
    NSArray *additional = [[record getAttributeDataElement:0x000D] getArrayValue];
    NSArray *protocols = [additional.firstObject getArrayValue];
    NSArray *interruptL2CAP = [protocols.firstObject getArrayValue];
    XCTAssertEqual([[interruptL2CAP.lastObject getNumberValue] unsignedIntValue], 0x0013U);
    NSArray *descriptorList = [[record getAttributeDataElement:0x0206] getArrayValue];
    NSArray *descriptorEntry = [descriptorList.firstObject getArrayValue];
    XCTAssertEqual([[descriptorEntry.firstObject getNumberValue] unsignedIntValue], 0x22U);
    XCTAssertEqualObjects([descriptorEntry.lastObject getValue], descriptor);
}

- (void)testMalformedHidpMessagesProtocolModesAndOutputLeds {
    AniCeHIDProtocol *protocol = [AniCeHIDProtocol new];
    NSArray *empty = [protocol consumePacket:[NSData data] control:YES];
    XCTAssertEqualObjects(empty.firstObject[@"data"], HIDParseHex(@"04"));
    NSMutableData *oversize = [NSMutableData dataWithLength:65];
    XCTAssertEqualObjects([[protocol consumePacket:oversize control:YES].firstObject objectForKey:@"data"], HIDParseHex(@"04"));
    XCTAssertEqualObjects([[protocol consumePacket:HIDParseHex(@"13 00") control:YES].firstObject objectForKey:@"data"], HIDParseHex(@"04"));
    XCTAssertEqualObjects([[protocol consumePacket:HIDParseHex(@"60") control:YES].firstObject objectForKey:@"data"], HIDParseHex(@"A0 01"));
    XCTAssertEqualObjects([[protocol consumePacket:HIDParseHex(@"72") control:YES].firstObject objectForKey:@"data"], HIDParseHex(@"04"));
    XCTAssertEqual(protocol.protocolMode, 1U);

    XCTAssertEqualObjects([[protocol consumePacket:HIDParseHex(@"52 01 05") control:YES].firstObject objectForKey:@"data"], HIDParseHex(@"00"));
    XCTAssertEqual(protocol.leds, 5);
    XCTAssertEqual([protocol consumePacket:HIDParseHex(@"A2 01 03") control:NO].count, 0U);
    XCTAssertEqual(protocol.leds, 3);

    NSArray *unknown = [protocol consumePacket:HIDParseHex(@"80") control:YES];
    XCTAssertEqualObjects(unknown.firstObject[@"data"], HIDParseHex(@"03"));
    XCTAssertEqual([protocol consumePacket:HIDParseHex(@"13") control:YES].count, 0U);
    XCTAssertTrue(protocol.suspended);
    NSString *error = nil;
    XCTAssertNil([protocol keyboardPacketWithModifiers:0 usages:@[] error:&error]);
    XCTAssertNotNil(error);
    [protocol consumePacket:HIDParseHex(@"14") control:YES];
    XCTAssertFalse(protocol.suspended);
    XCTAssertTrue(protocol.unplugRequested == NO);
    [protocol consumePacket:HIDParseHex(@"15") control:YES];
    XCTAssertTrue(protocol.unplugRequested);

    AniCeHIDProtocol *boot = [AniCeHIDProtocol new];
    [boot consumePacket:HIDParseHex(@"70") control:YES];
    XCTAssertEqual(boot.protocolMode, 0U);
    XCTAssertEqualObjects([[boot consumePacket:HIDParseHex(@"60") control:YES].firstObject objectForKey:@"data"], HIDParseHex(@"A0 00"));
    XCTAssertNil([boot mousePacketWithButtons:0 deltaX:0 deltaY:0 wheel:1 error:&error]);
}

- (void)testAddressNormalizationAndKeyFixtures {
    XCTAssertEqualObjects([AniCeHIDProtocol normalizedAddress:@"aa-bb-cc-dd-ee-ff"], @"AA:BB:CC:DD:EE:FF");
    XCTAssertEqualObjects([AniCeHIDProtocol normalizedAddress:@"AABBCCDDEEFF"], @"AA:BB:CC:DD:EE:FF");
    XCTAssertNil([AniCeHIDProtocol normalizedAddress:@"AA:BB:CC:DD:EE"]);
    XCTAssertNil([AniCeHIDProtocol normalizedAddress:@"AA:BB:CC:DD:EE:GG"]);
    XCTAssertEqual([AniCeHIDProtocol usageForMacKeyCode:0x00], 0x04);
    XCTAssertEqualObjects([AniCeHIDProtocol keyForASCIICharacter:'A'], (@[@4, @2]));
    XCTAssertEqualObjects([AniCeHIDProtocol keyForASCIICharacter:'\n'], (@[@0x28, @0]));
    XCTAssertEqual([AniCeHIDProtocol physicalModifiersForFlags:(NSEventModifierFlagCommand | NSEventModifierFlagShift)], 3);
    XCTAssertEqual([AniCeHIDProtocol physicalModifiersForFlags:NSEventModifierFlagControl], 1);
    XCTAssertEqual([AniCeHIDProtocol physicalModifiersForFlags:NSEventModifierFlagOption], 4);

    AniCeHIDProtocol *protocol = [AniCeHIDProtocol new];
    NSString *error = nil;
    XCTAssertNil([protocol keyboardPacketWithModifiers:0 usages:@[@0] error:&error]);
    XCTAssertNil([protocol keyboardPacketWithModifiers:0 usages:@[@0x66] error:&error]);
    XCTAssertNil(([protocol keyboardPacketWithModifiers:0 usages:@[@1, @2, @3, @4, @5, @6, @7] error:&error]));
    XCTAssertNil([protocol mousePacketWithButtons:4 deltaX:0 deltaY:0 wheel:0 error:&error]);
    XCTAssertNil([protocol mousePacketWithButtons:0 deltaX:-128 deltaY:0 wheel:0 error:&error]);
    XCTAssertNil([protocol mousePacketWithButtons:0 deltaX:0 deltaY:0 wheel:9 error:&error]);
}

- (void)testOpenChannelCallbackAndRegistrationFailurePaths {
    Class sessionClass = NSClassFromString(@"AniCeHIDSession");
    XCTAssertNotNil(sessionClass);
    id session = [sessionClass new];
    HIDMockOpenDevice *device = [HIDMockOpenDevice new];
    device.channel = [HIDMockChannel new];
    device.openResult = kIOReturnSuccess;
    device.emitCallback = YES;
    device.callbackStatus = kIOReturnSuccess;
    [session setDevice:(IOBluetoothDevice *)device];
    [session setConnecting:YES];
    [session setCallbackTimeout:0.01];
    NSString *error = nil;

    XCTAssertTrue([session openPSM:0x0011 error:&error]);
    XCTAssertEqual(device.channel.delegateRegistrations, 1U);
    XCTAssertEqual((id)[session control], (id)device.channel);

    [session setControl:nil];
    device.channel = [HIDMockChannel new];
    device.channel.delegateStatus = kIOReturnNotPermitted;
    XCTAssertFalse([session openPSM:0x0013 error:&error]);
    XCTAssertEqual(device.channel.closeCount, 1U);
    XCTAssertNil(device.channel.retainedDelegate);
    XCTAssertNil([session valueForKey:@"interrupt"]);

    device.channel = [HIDMockChannel new];
    device.emitCallback = NO;
    XCTAssertFalse([session openPSM:0x0011 error:&error]);
    XCTAssertTrue([error containsString:@"timed out"]);

    device.channel = [HIDMockChannel new];
    device.emitCallback = YES;
    device.emitEarlyCallback = YES;
    device.channel.openStatus = kIOReturnSuccess;
    XCTAssertTrue([session openPSM:0x0013 error:&error]);
    XCTAssertEqual([session valueForKey:@"interrupt"], (id)device.channel);

    [session setInterrupt:nil];
    device.channel = [HIDMockChannel new];
    device.returnedPSM = 0x1001;
    XCTAssertFalse([session openPSM:0x0013 error:&error]);
    XCTAssertEqual(device.channel.closeCount, 1U);
    XCTAssertNil([session valueForKey:@"interrupt"]);
}

- (void)testWrongDeviceAndWrongPsmCallbacksDoNotCompleteAnOpen {
    Class sessionClass = NSClassFromString(@"AniCeHIDSession");
    id session = [sessionClass new];
    HIDMockOpenDevice *device = [HIDMockOpenDevice new];
    device.channel = [HIDMockChannel new];
    device.callbackChannel = [HIDMockChannel new];
    device.callbackChannel.device = (IOBluetoothDevice *)[NSObject new];
    device.openResult = kIOReturnSuccess;
    device.emitCallback = NO;
    device.emitEarlyCallback = YES;
    device.callbackStatus = kIOReturnSuccess;
    [session setDevice:(IOBluetoothDevice *)device];
    [session setConnecting:YES];
    [session setCallbackTimeout:0.01];
    NSString *error = nil;

    XCTAssertFalse([session openPSM:0x0011 error:&error]);
    XCTAssertTrue([error containsString:@"timed out"]);

    device.channel = [HIDMockChannel new];
    device.callbackChannel = [HIDMockChannel new];
    device.callbackChannel.PSM = 0x0011;
    device.callbackChannel.device = (IOBluetoothDevice *)device;
    XCTAssertFalse([session openPSM:0x0011 error:&error]);
    XCTAssertTrue([error containsString:@"callback did not belong"]);
    XCTAssertEqual(device.callbackChannel.closeCount, 1U);

    device.channel = [HIDMockChannel new];
    device.callbackChannel = [HIDMockChannel new];
    device.callbackChannel.PSM = 0x0013;
    device.callbackChannel.device = (IOBluetoothDevice *)device;
    device.emitCallback = NO;
    device.emitEarlyCallback = YES;
    XCTAssertFalse([session openPSM:0x0011 error:&error]);
    XCTAssertTrue([error containsString:@"timed out"]);
}

- (void)testBluetoothInputRequiresAuthenticationForTheCurrentPairedConnection {
    Class sessionClass = NSClassFromString(@"AniCeHIDSession");
    id session = [sessionClass new];
    HIDMockSecurityDevice *device = [HIDMockSecurityDevice new];
    device.paired = YES;
    device.connected = YES;
    device.encryptionMode = kEncryptionDisabled;
    [session setDevice:(IOBluetoothDevice *)device];
    NSString *error = nil;
    XCTAssertFalse([session authenticatedLinkWithError:&error]);
    [session setAuthenticated:YES];
    XCTAssertTrue([session authenticatedLinkWithError:&error]);
    XCTAssertEqual(device.encryptionReadCount, 0U);
    device.paired = NO;
    XCTAssertFalse([session authenticatedLinkWithError:&error]);
    device.paired = YES;
    device.connected = NO;
    XCTAssertFalse([session authenticatedLinkWithError:&error]);
    device.connected = YES;
    [(NSObject *)session disconnect];
    [session setDevice:(IOBluetoothDevice *)device];
    XCTAssertFalse([session authenticatedLinkWithError:&error], @"Disconnect must revoke the previous connection's authentication.");
}

- (void)testCancelledConnectionWaitStopsBeforeItsCallbackTimeout {
    id session = [NSClassFromString(@"AniCeHIDSession") new];
    [session setCallbackTimeout:5];
    [session setCancellationRequested:^BOOL{ return YES; }];
    NSString *error = nil;
    NSDate *started = [NSDate date];
    XCTAssertFalse([session waitForCompletion:@"Opening HID" error:&error]);
    XCTAssertTrue([error containsString:@"cancelled"]);
    XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:started], 0.1);
}

- (void)testAdapterShutdownFinishesWithinItsBoundedWait {
    AniCeHIDAdapter *adapter = [AniCeHIDAdapter new];
    NSDate *started = [NSDate date];
    [adapter shutdown];
    XCTAssertLessThan([[NSDate date] timeIntervalSinceDate:started], 1.0);
}

- (void)testMouseGetReportIsStationaryAndResumeReleasesHeldReports {
    id session = [NSClassFromString(@"AniCeHIDSession") new];
    HIDMockSecurityDevice *device = [HIDMockSecurityDevice new];
    device.paired = YES; device.connected = YES;
    device.encryptionMode = kEncryptionOnlyForPointToPointPackets;
    HIDMockChannel *control = [HIDMockChannel new], *interrupt = [HIDMockChannel new];
    control.PSM = 0x11; interrupt.PSM = 0x13;
    control.device = interrupt.device = (IOBluetoothDevice *)device;
    [session setDevice:(IOBluetoothDevice *)device];
    [session setControl:(IOBluetoothL2CAPChannel *)control];
    [session setInterrupt:(IOBluetoothL2CAPChannel *)interrupt];
    [session setReady:YES];
    [session setAuthenticated:YES];
    NSString *error = nil;
    XCTAssertTrue([session sendMouseButtons:1 deltaX:30 deltaY:-20 wheel:2 error:&error]);
    AniCeHIDProtocol *protocol = [session valueForKey:@"protocol"];
    XCTAssertEqualObjects([protocol consumePacket:HIDParseHex(@"41 0A") control:YES].firstObject[@"data"],
                          HIDParseHex(@"A1 0A 01 00 00 00 00"));
    XCTAssertTrue([session sendKeyboardModifiers:2 usages:@[@4] error:&error]);
    XCTAssertTrue([session sendNavigationUsage:0x0224 pressed:YES error:&error]);
    uint8_t suspend = 0x13, resume = 0x14;
    [session l2capChannelData:(IOBluetoothL2CAPChannel *)control data:&suspend length:1];
    XCTAssertNil([protocol navigationPacketWithUsage:0x0224 pressed:YES error:&error]);
    [interrupt.packets removeAllObjects];
    [session l2capChannelData:(IOBluetoothL2CAPChannel *)control data:&resume length:1];
    XCTAssertEqualObjects(interrupt.packets, (@[HIDParseHex(@"A1 01 00 00 00 00 00 00 00 00 00"),
      HIDParseHex(@"A1 02 00 00"), HIDParseHex(@"A1 0A 00 00 00 00 00")]));
}

@end
