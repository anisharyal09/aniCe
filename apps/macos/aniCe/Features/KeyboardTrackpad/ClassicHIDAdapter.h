// SPDX-License-Identifier: GPL-3.0-or-later
// Defines aniCe's local Bluetooth HID boundary and its independently testable report protocol.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <dispatch/dispatch.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^AniCeHIDCompletion)(BOOL success, NSString * _Nullable errorMessage);
typedef void (^AniCeHIDDevicesCompletion)(NSArray<NSDictionary<NSString *, NSString *> *> *devices);
typedef void (^AniCeHIDStateChanged)(uint64_t generation, BOOL ready, BOOL suspended, BOOL reportProtocol, NSString * _Nullable message);

/// Pure HIDP/descriptor state shared by the Bluetooth adapter and protocol fixtures.
@interface AniCeHIDProtocol : NSObject
@property(nonatomic, readonly) NSUInteger protocolMode;
@property(nonatomic, readonly, getter=isSuspended) BOOL suspended;
@property(nonatomic, readonly) BOOL unplugRequested;
@property(nonatomic, readonly) uint8_t leds;
@property(nonatomic, readonly) NSData *keyboardReport;
@property(nonatomic, readonly) NSData *mouseReport;
@property(nonatomic, readonly) uint16_t consumerControls;

+ (NSData *)reportDescriptor;
+ (NSDictionary *)serviceRecordDictionary;
+ (nullable NSString *)serviceRecordValidationError:(nullable IOBluetoothSDPServiceRecord *)record;
+ (nullable NSString *)normalizedAddress:(NSString *)address;
+ (nullable NSArray<NSNumber *> *)keyForASCIICharacter:(unichar)character;
+ (uint8_t)usageForMacKeyCode:(unsigned short)keyCode;
+ (uint8_t)physicalModifiersForFlags:(NSEventModifierFlags)flags;
+ (NSData *)keyboardPayloadWithModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages;
+ (BOOL)callbackDevice:(id)callbackDevice matchesDevice:(id)expectedDevice
                   psm:(uint16_t)callbackPSM expectedPSM:(uint16_t)expectedPSM;
- (nullable NSData *)keyboardPacketWithModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages
                                           error:(NSString * _Nullable * _Nullable)error;
- (nullable NSData *)mousePacketWithButtons:(uint8_t)buttons deltaX:(NSInteger)x deltaY:(NSInteger)y wheel:(NSInteger)wheel
                                      error:(NSString * _Nullable * _Nullable)error;
- (nullable NSData *)navigationPacketWithUsage:(uint16_t)usage pressed:(BOOL)pressed
                                          error:(NSString * _Nullable * _Nullable)error;
- (NSArray<NSDictionary<NSString *, id> *> *)consumePacket:(NSData *)packet control:(BOOL)control;
- (void)reset;
@end

/// Public app boundary. IOBluetooth operations stay on its private run-loop worker.
/// Completion and state callbacks are delivered on the main queue.
@interface AniCeHIDAdapter : NSObject
@property(nonatomic, copy, nullable) AniCeHIDStateChanged stateChanged;
- (void)enumeratePairedDevices:(AniCeHIDDevicesCompletion)completion;
- (BOOL)connectAddress:(NSString *)address generation:(uint64_t)generation completion:(AniCeHIDCompletion)completion;
- (BOOL)sendKeyboardModifiers:(uint8_t)modifiers usages:(NSArray<NSNumber *> *)usages completion:(AniCeHIDCompletion)completion;
- (BOOL)sendMouseButtons:(uint8_t)buttons deltaX:(NSInteger)x deltaY:(NSInteger)y wheel:(NSInteger)wheel completion:(AniCeHIDCompletion)completion;
- (BOOL)sendNavigationUsage:(uint16_t)usage pressed:(BOOL)pressed completion:(AniCeHIDCompletion)completion;
- (BOOL)disconnectWithCompletion:(nullable dispatch_block_t)completion;
- (void)shutdown;
@end

NS_ASSUME_NONNULL_END
