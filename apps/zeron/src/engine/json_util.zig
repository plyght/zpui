//! std.json adapters for serde representations std.json lacks natively.
//!
//! - `Tagged(T, tag)`: serde internally-tagged enums (`#[serde(tag = "kind")]`):
//!   `{"kind":"text","id":"p1","text":"hi"}` ⇄ `union(enum) { text: struct{ id, text }, ... }`.
//!   Union field names are the exact wire tags; `void` payloads are tag-only variants.
//! - `OpenEnum(T, fallback)`: string enums with `#[serde(other)]`.
//!
//! Usage inside the union/enum:
//! ```
//! pub const jsonParse = json_util.Tagged(@This(), "kind").jsonParse;
//! pub const jsonParseFromValue = json_util.Tagged(@This(), "kind").jsonParseFromValue;
//! pub const jsonStringify = json_util.Tagged(@This(), "kind").jsonStringify;
//! ```

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub fn Tagged(comptime T: type, comptime tag: []const u8) type {
    const info = @typeInfo(T).@"union";
    return struct {
        pub fn jsonParse(gpa: Allocator, source: anytype, options: json.ParseOptions) json.ParseError(@TypeOf(source.*))!T {
            const value = try json.innerParse(json.Value, gpa, source, options);
            return jsonParseFromValue(gpa, value, options);
        }

        pub fn jsonParseFromValue(gpa: Allocator, value: json.Value, options: json.ParseOptions) json.ParseFromValueError!T {
            if (value != .object) return error.UnexpectedToken;
            const tag_value = value.object.get(tag) orelse return error.MissingField;
            if (tag_value != .string) return error.UnexpectedToken;
            // The tag itself is a sibling field the payload struct doesn't declare.
            var inner = options;
            inner.ignore_unknown_fields = true;
            inline for (info.field_names, info.field_types) |name, Payload| {
                if (std.mem.eql(u8, name, tag_value.string)) {
                    if (Payload == void) return @unionInit(T, name, {});
                    return @unionInit(T, name, try json.innerParseFromValue(Payload, gpa, value, inner));
                }
            }
            return error.InvalidEnumTag;
        }

        pub fn jsonStringify(self: T, jws: anytype) !void {
            try jws.beginObject();
            try jws.objectField(tag);
            switch (self) {
                inline else => |payload, t| {
                    try jws.write(@tagName(t));
                    const Payload = @TypeOf(payload);
                    if (Payload != void) {
                        const s = @typeInfo(Payload).@"struct";
                        inline for (s.field_names, s.field_types) |field, F| {
                            const v = @field(payload, field);
                            const skip = @typeInfo(F) == .optional and v == null and
                                !jws.options.emit_null_optional_fields;
                            if (!skip) {
                                try jws.objectField(field);
                                try jws.write(v);
                            }
                        }
                    }
                },
            }
            try jws.endObject();
        }
    };
}

/// A string enum that decodes unrecognized values to `fallback`.
pub fn OpenEnum(comptime T: type, comptime fallback: T) type {
    return struct {
        pub fn jsonParse(gpa: Allocator, source: anytype, options: json.ParseOptions) json.ParseError(@TypeOf(source.*))!T {
            const value = try json.innerParse(json.Value, gpa, source, options);
            return jsonParseFromValue(gpa, value, options);
        }

        pub fn jsonParseFromValue(_: Allocator, value: json.Value, _: json.ParseOptions) json.ParseFromValueError!T {
            return switch (value) {
                .string => |s| std.meta.stringToEnum(T, s) orelse fallback,
                else => error.UnexpectedToken,
            };
        }
    };
}

/// Stringify `value` with serde-compatible settings (null optionals omitted).
pub fn stringifyAlloc(gpa: Allocator, value: anytype) error{OutOfMemory}![]u8 {
    return json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
}
