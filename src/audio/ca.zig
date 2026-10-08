//! Hand-written C bindings for the slices of CoreAudio (AudioHardware.h,
//! AudioHardwareBase.h) and AudioToolbox (AudioComponent.h, AudioUnit
//! properties, AudioOutputUnit.h) used by `coreaudio.zig` and
//! `activity_mac.zig`, in the style of src/platform/mac/cf.zig.
//! Only analyzed on macOS.

pub const OSStatus = i32;
pub const AudioObjectID = u32;
pub const Boolean = u8;

/// Four-character code, as the C headers' 'abcd' literals.
pub fn fcc(comptime s: *const [4]u8) u32 {
    return @as(u32, s[0]) << 24 | @as(u32, s[1]) << 16 | @as(u32, s[2]) << 8 | s[3];
}

pub const AudioObjectPropertyAddress = extern struct {
    selector: u32,
    scope: u32 = scope_global,
    element: u32 = element_main,
};

pub const system_object: AudioObjectID = 1;
pub const scope_global = fcc("glob");
pub const scope_input = fcc("inpt");
pub const scope_output = fcc("outp");
pub const element_main: u32 = 0;

pub const hw_default_output_device = fcc("dOut");
pub const hw_default_input_device = fcc("dIn ");
/// macOS 14.2+.
pub const hw_process_object_list = fcc("prs#");
pub const process_pid = fcc("ppid");
pub const process_is_running_input = fcc("piri");
pub const process_is_running_output = fcc("piro");
pub const dev_buffer_frame_size = fcc("fsiz");
pub const dev_buffer_frame_size_range = fcc("fsz#");
pub const dev_nominal_sample_rate = fcc("nsrt");
pub const dev_latency = fcc("ltnc");
pub const dev_safety_offset = fcc("saft");
pub const dev_is_running_somewhere = fcc("gone");

pub const AudioValueRange = extern struct { min: f64, max: f64 };

pub const PropertyListenerProc = *const fn (AudioObjectID, u32, [*]const AudioObjectPropertyAddress, ?*anyopaque) callconv(.c) OSStatus;

pub extern "c" fn AudioObjectHasProperty(id: AudioObjectID, addr: *const AudioObjectPropertyAddress) Boolean;
pub extern "c" fn AudioObjectGetPropertyDataSize(id: AudioObjectID, addr: *const AudioObjectPropertyAddress, qual_size: u32, qual: ?*const anyopaque, size: *u32) OSStatus;
pub extern "c" fn AudioObjectGetPropertyData(id: AudioObjectID, addr: *const AudioObjectPropertyAddress, qual_size: u32, qual: ?*const anyopaque, size: *u32, data: *anyopaque) OSStatus;
pub extern "c" fn AudioObjectSetPropertyData(id: AudioObjectID, addr: *const AudioObjectPropertyAddress, qual_size: u32, qual: ?*const anyopaque, size: u32, data: *const anyopaque) OSStatus;
pub extern "c" fn AudioObjectAddPropertyListener(id: AudioObjectID, addr: *const AudioObjectPropertyAddress, proc: PropertyListenerProc, client: ?*anyopaque) OSStatus;
pub extern "c" fn AudioObjectRemovePropertyListener(id: AudioObjectID, addr: *const AudioObjectPropertyAddress, proc: PropertyListenerProc, client: ?*anyopaque) OSStatus;

/// Reads a fixed-size property; null on error.
pub fn get(comptime T: type, id: AudioObjectID, addr: AudioObjectPropertyAddress) ?T {
    var v: T = undefined;
    var size: u32 = @sizeOf(T);
    if (AudioObjectGetPropertyData(id, &addr, 0, null, &size, @ptrCast(&v)) != 0 or size != @sizeOf(T)) return null;
    return v;
}

// AudioToolbox -------------------------------------------------------------

pub const AudioComponent = *opaque {};
pub const AudioUnit = *opaque {};

pub const AudioComponentDescription = extern struct {
    componentType: u32,
    componentSubType: u32,
    componentManufacturer: u32,
    componentFlags: u32 = 0,
    componentFlagsMask: u32 = 0,
};

pub const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: u32,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32 = 0,
};

pub const AudioBuffer = extern struct { mNumberChannels: u32, mDataByteSize: u32, mData: ?*anyopaque };
pub const AudioBufferList = extern struct { mNumberBuffers: u32, mBuffers: [1]AudioBuffer };
pub const AudioTimeStamp = opaque {};

pub const AURenderCallback = *const fn (?*anyopaque, *u32, *const AudioTimeStamp, u32, u32, ?*AudioBufferList) callconv(.c) OSStatus;
pub const AURenderCallbackStruct = extern struct { inputProc: AURenderCallback, inputProcRefCon: ?*anyopaque };

pub const kAudioUnitType_Output = fcc("auou");
pub const kAudioUnitSubType_DefaultOutput = fcc("def ");
pub const kAudioUnitManufacturer_Apple = fcc("appl");
pub const kAudioFormatLinearPCM = fcc("lpcm");
pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;
pub const kAudioUnitProperty_StreamFormat: u32 = 8;
pub const kAudioUnitProperty_SetRenderCallback: u32 = 23;
pub const kAudioUnitProperty_MaximumFramesPerSlice: u32 = 14;
pub const kAudioOutputUnitProperty_CurrentDevice: u32 = 2000;
pub const kAudioUnitScope_Global: u32 = 0;
pub const kAudioUnitScope_Input: u32 = 1;
pub const kAudioUnitScope_Output: u32 = 2;

pub extern "c" fn AudioComponentFindNext(after: ?AudioComponent, desc: *const AudioComponentDescription) ?AudioComponent;
pub extern "c" fn AudioComponentInstanceNew(comp: AudioComponent, out: *?AudioUnit) OSStatus;
pub extern "c" fn AudioComponentInstanceDispose(unit: AudioUnit) OSStatus;
pub extern "c" fn AudioUnitInitialize(unit: AudioUnit) OSStatus;
pub extern "c" fn AudioUnitUninitialize(unit: AudioUnit) OSStatus;
pub extern "c" fn AudioUnitSetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *const anyopaque, size: u32) OSStatus;
pub extern "c" fn AudioUnitGetProperty(unit: AudioUnit, id: u32, scope: u32, element: u32, data: *anyopaque, size: *u32) OSStatus;
pub extern "c" fn AudioOutputUnitStart(unit: AudioUnit) OSStatus;
pub extern "c" fn AudioOutputUnitStop(unit: AudioUnit) OSStatus;
