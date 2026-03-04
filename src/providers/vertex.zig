const std = @import("std");
const root = @import("root.zig");
const gemini = @import("gemini.zig");
const config_types = @import("../config_types.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;

/// Authentication method for Vertex AI.
pub const VertexAuth = union(enum) {
    /// Token from config models.providers.vertex.api_key.
    explicit_token: []const u8,
    /// Token from VERTEX_API_KEY env var.
    env_vertex_api_key: []const u8,
    /// Token from VERTEX_OAUTH_TOKEN env var.
    env_vertex_oauth_token: []const u8,
    /// Token from GOOGLE_OAUTH_ACCESS_TOKEN env var.
    env_google_oauth_access_token: []const u8,

    pub fn credential(self: VertexAuth) []const u8 {
        return switch (self) {
            .explicit_token => |v| v,
            .env_vertex_api_key => |v| v,
            .env_vertex_oauth_token => |v| v,
            .env_google_oauth_access_token => |v| v,
        };
    }

    pub fn source(self: VertexAuth) []const u8 {
        return switch (self) {
            .explicit_token => "config",
            .env_vertex_api_key => "VERTEX_API_KEY env var",
            .env_vertex_oauth_token => "VERTEX_OAUTH_TOKEN env var",
            .env_google_oauth_access_token => "GOOGLE_OAUTH_ACCESS_TOKEN env var",
        };
    }
};

const VertexBase = union(enum) {
    /// models.providers.vertex.base_url (unowned)
    config: []const u8,
    /// VERTEX_BASE_URL (owned)
    env: []const u8,
    /// Built from VERTEX_PROJECT_ID + VERTEX_LOCATION (owned)
    derived: []const u8,

    pub fn value(self: VertexBase) []const u8 {
        return switch (self) {
            .config => |v| v,
            .env => |v| v,
            .derived => |v| v,
        };
    }

    pub fn source(self: VertexBase) []const u8 {
        return switch (self) {
            .config => "base_url config",
            .env => "VERTEX_BASE_URL env var",
            .derived => "VERTEX_PROJECT_ID/VERTEX_LOCATION env vars",
        };
    }
};

/// Vertex AI Gemini provider.
///
/// Endpoint resolution order:
/// 1. models.providers.vertex.base_url
/// 2. VERTEX_BASE_URL
/// 3. Build from VERTEX_PROJECT_ID (+ optional VERTEX_LOCATION, default: global)
pub const VertexProvider = struct {
    auth: ?VertexAuth,
    base: ?VertexBase,
    allocator: std.mem.Allocator,

    const DEFAULT_MAX_OUTPUT_TOKENS: u32 = config_types.DEFAULT_MODEL_MAX_TOKENS;

    pub fn init(allocator: std.mem.Allocator, api_key: ?[]const u8, base_url: ?[]const u8) VertexProvider {
        return .{
            .auth = resolveAuth(allocator, api_key),
            .base = resolveBase(allocator, base_url),
            .allocator = allocator,
        };
    }

    fn resolveAuth(allocator: std.mem.Allocator, api_key: ?[]const u8) ?VertexAuth {
        if (api_key) |key| {
            const trimmed = std.mem.trim(u8, key, " \t\r\n");
            if (trimmed.len > 0) {
                return .{ .explicit_token = trimmed };
            }
        }

        if (loadNonEmptyEnv(allocator, "VERTEX_API_KEY")) |value| {
            return .{ .env_vertex_api_key = value };
        }
        if (loadNonEmptyEnv(allocator, "VERTEX_OAUTH_TOKEN")) |value| {
            return .{ .env_vertex_oauth_token = value };
        }
        if (loadNonEmptyEnv(allocator, "GOOGLE_OAUTH_ACCESS_TOKEN")) |value| {
            return .{ .env_google_oauth_access_token = value };
        }

        return null;
    }

    fn resolveBase(allocator: std.mem.Allocator, base_url: ?[]const u8) ?VertexBase {
        if (base_url) |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                return .{ .config = trimmed };
            }
        }

        if (loadNonEmptyEnv(allocator, "VERTEX_BASE_URL")) |env_base| {
            return .{ .env = env_base };
        }

        const project = loadNonEmptyEnv(allocator, "VERTEX_PROJECT_ID") orelse return null;
        defer allocator.free(project);

        const location_owned = loadNonEmptyEnv(allocator, "VERTEX_LOCATION");
        defer if (location_owned) |loc| allocator.free(loc);
        const location = if (location_owned) |loc| loc else "global";

        const built = buildDefaultBase(allocator, project, location) catch return null;
        return .{ .derived = built };
    }

    fn buildDefaultBase(allocator: std.mem.Allocator, project_id: []const u8, location: []const u8) ![]u8 {
        var host_owned: ?[]u8 = null;
        defer if (host_owned) |h| allocator.free(h);

        const host: []const u8 = if (std.mem.eql(u8, location, "global"))
            "https://aiplatform.googleapis.com"
        else blk: {
            const h = try std.fmt.allocPrint(allocator, "https://{s}-aiplatform.googleapis.com", .{location});
            host_owned = h;
            break :blk h;
        };

        return std.fmt.allocPrint(
            allocator,
            "{s}/v1/projects/{s}/locations/{s}/publishers/google/models",
            .{ host, project_id, location },
        );
    }

    fn loadNonEmptyEnv(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
        if (std.process.getEnvVarOwned(allocator, name)) |value| {
            defer allocator.free(value);
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) {
                return allocator.dupe(u8, trimmed) catch null;
            }
            return null;
        } else |_| {
            return null;
        }
    }

    pub fn authSource(self: VertexProvider) []const u8 {
        if (self.auth) |auth| return auth.source();
        return "none";
    }

    pub fn endpointSource(self: VertexProvider) []const u8 {
        if (self.base) |b| return b.source();
        return "none";
    }

    pub fn provider(self: *VertexProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .supports_vision = supportsVisionImpl,
        .supports_streaming = supportsStreamingImpl,
        .stream_chat = streamChatImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) anyerror![]const u8 {
        const self: *VertexProvider = @ptrCast(@alignCast(ptr));
        const auth = self.auth orelse return error.CredentialsNotSet;
        const base = self.base orelse return error.VertexBaseUrlNotSet;

        const url = try buildGenerateUrl(allocator, base.value(), model);
        defer allocator.free(url);

        const body = try buildSimpleRequestBody(allocator, system_prompt, message, temperature);
        defer allocator.free(body);

        var auth_hdr_buf: [1024]u8 = undefined;
        const auth_hdr = std.fmt.bufPrint(&auth_hdr_buf, "Authorization: Bearer {s}", .{auth.credential()}) catch return error.VertexApiError;

        const resp_body = root.curlPostTimed(allocator, url, body, &.{auth_hdr}, 0) catch return error.VertexApiError;
        defer allocator.free(resp_body);

        return gemini.GeminiProvider.parseResponse(allocator, resp_body);
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
    ) anyerror!ChatResponse {
        const self: *VertexProvider = @ptrCast(@alignCast(ptr));
        const auth = self.auth orelse return error.CredentialsNotSet;
        const base = self.base orelse return error.VertexBaseUrlNotSet;

        const url = try buildGenerateUrl(allocator, base.value(), model);
        defer allocator.free(url);

        const body = try buildChatRequestBody(allocator, request, temperature);
        defer allocator.free(body);

        var auth_hdr_buf: [1024]u8 = undefined;
        const auth_hdr = std.fmt.bufPrint(&auth_hdr_buf, "Authorization: Bearer {s}", .{auth.credential()}) catch return error.VertexApiError;

        const resp_body = root.curlPostTimed(allocator, url, body, &.{auth_hdr}, request.timeout_secs) catch return error.VertexApiError;
        defer allocator.free(resp_body);

        const text = try gemini.GeminiProvider.parseResponse(allocator, resp_body);
        return ChatResponse{ .content = text };
    }

    fn streamChatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
        callback: root.StreamCallback,
        callback_ctx: *anyopaque,
    ) anyerror!root.StreamChatResult {
        const self: *VertexProvider = @ptrCast(@alignCast(ptr));
        const auth = self.auth orelse return error.CredentialsNotSet;
        const base = self.base orelse return error.VertexBaseUrlNotSet;

        const url = try buildStreamUrl(allocator, base.value(), model);
        defer allocator.free(url);

        const body = try buildChatRequestBody(allocator, request, temperature);
        defer allocator.free(body);

        var auth_hdr_buf: [1024]u8 = undefined;
        const auth_hdr = std.fmt.bufPrint(&auth_hdr_buf, "Authorization: Bearer {s}", .{auth.credential()}) catch return error.VertexApiError;
        const headers = [_][]const u8{auth_hdr};

        return gemini.GeminiProvider.curlStreamGemini(
            allocator,
            url,
            body,
            &headers,
            request.timeout_secs,
            callback,
            callback_ctx,
        );
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn supportsVisionImpl(_: *anyopaque) bool {
        return true;
    }

    fn supportsStreamingImpl(_: *anyopaque) bool {
        return true;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "Vertex";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *VertexProvider = @ptrCast(@alignCast(ptr));

        if (self.auth) |auth| {
            switch (auth) {
                .env_vertex_api_key => |token| self.allocator.free(token),
                .env_vertex_oauth_token => |token| self.allocator.free(token),
                .env_google_oauth_access_token => |token| self.allocator.free(token),
                else => {},
            }
        }

        if (self.base) |base| {
            switch (base) {
                .env => |url| self.allocator.free(url),
                .derived => |url| self.allocator.free(url),
                else => {},
            }
        }

        self.auth = null;
        self.base = null;
    }
};

fn trimTrailingSlash(url: []const u8) []const u8 {
    return std.mem.trimRight(u8, url, "/");
}

fn normalizeModelName(model: []const u8) []const u8 {
    if (std.mem.startsWith(u8, model, "models/")) {
        return model["models/".len..];
    }

    const publisher_prefix = "publishers/google/models/";
    if (std.mem.startsWith(u8, model, publisher_prefix)) {
        return model[publisher_prefix.len..];
    }

    const resource_marker = "/publishers/google/models/";
    if (std.mem.indexOf(u8, model, resource_marker)) |idx| {
        return model[idx + resource_marker.len ..];
    }

    return model;
}

pub fn buildGenerateUrl(allocator: std.mem.Allocator, base: []const u8, model: []const u8) ![]u8 {
    const root_url = trimTrailingSlash(base);
    const model_name = normalizeModelName(model);
    return std.fmt.allocPrint(allocator, "{s}/{s}:generateContent", .{ root_url, model_name });
}

pub fn buildStreamUrl(allocator: std.mem.Allocator, base: []const u8, model: []const u8) ![]u8 {
    const root_url = trimTrailingSlash(base);
    const model_name = normalizeModelName(model);
    return std.fmt.allocPrint(allocator, "{s}/{s}:streamGenerateContent?alt=sse", .{ root_url, model_name });
}

pub fn buildSimpleRequestBody(
    allocator: std.mem.Allocator,
    system_prompt: ?[]const u8,
    message: []const u8,
    temperature: f64,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":");
    try root.appendJsonString(&buf, allocator, message);
    try buf.appendSlice(allocator, "}]}]");

    if (system_prompt) |sys| {
        try buf.appendSlice(allocator, ",\"system_instruction\":{\"parts\":[{\"text\":");
        try root.appendJsonString(&buf, allocator, sys);
        try buf.appendSlice(allocator, "}]}");
    }

    try buf.appendSlice(allocator, ",\"generationConfig\":{\"temperature\":");

    var temp_buf: [16]u8 = undefined;
    const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{temperature}) catch return error.VertexApiError;
    try buf.appendSlice(allocator, temp_str);
    try buf.appendSlice(allocator, ",\"maxOutputTokens\":");

    var max_buf: [16]u8 = undefined;
    const max_str = std.fmt.bufPrint(&max_buf, "{d}", .{VertexProvider.DEFAULT_MAX_OUTPUT_TOKENS}) catch return error.VertexApiError;
    try buf.appendSlice(allocator, max_str);
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

fn buildChatRequestBody(
    allocator: std.mem.Allocator,
    request: ChatRequest,
    temperature: f64,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    var system_prompt: ?[]const u8 = null;
    for (request.messages) |msg| {
        if (msg.role == .system) {
            system_prompt = msg.content;
            break;
        }
    }

    try buf.appendSlice(allocator, "{\"contents\":[");
    var count: usize = 0;

    for (request.messages) |msg| {
        if (msg.role == .system) continue;
        if (count > 0) try buf.append(allocator, ',');
        count += 1;

        const role_str: []const u8 = switch (msg.role) {
            .user, .tool => "user",
            .assistant => "model",
            .system => unreachable,
        };

        try buf.appendSlice(allocator, "{\"role\":\"");
        try buf.appendSlice(allocator, role_str);
        try buf.appendSlice(allocator, "\",\"parts\":[");

        if (msg.content_parts) |parts| {
            for (parts, 0..) |part, j| {
                if (j > 0) try buf.append(allocator, ',');
                switch (part) {
                    .text => |text| {
                        try buf.appendSlice(allocator, "{\"text\":");
                        try root.appendJsonString(&buf, allocator, text);
                        try buf.append(allocator, '}');
                    },
                    .image_base64 => |img| {
                        try buf.appendSlice(allocator, "{\"inlineData\":{\"mimeType\":");
                        try root.appendJsonString(&buf, allocator, img.media_type);
                        try buf.appendSlice(allocator, ",\"data\":\"");
                        try buf.appendSlice(allocator, img.data);
                        try buf.appendSlice(allocator, "\"}}");
                    },
                    .image_url => |img| {
                        try buf.appendSlice(allocator, "{\"text\":");
                        var text_buf: std.ArrayListUnmanaged(u8) = .empty;
                        defer text_buf.deinit(allocator);
                        try text_buf.appendSlice(allocator, "[Image: ");
                        try text_buf.appendSlice(allocator, img.url);
                        try text_buf.appendSlice(allocator, "]");
                        try root.appendJsonString(&buf, allocator, text_buf.items);
                        try buf.append(allocator, '}');
                    },
                }
            }
        } else {
            try buf.appendSlice(allocator, "{\"text\":");
            try root.appendJsonString(&buf, allocator, msg.content);
            try buf.append(allocator, '}');
        }

        try buf.appendSlice(allocator, "]}");
    }

    try buf.append(allocator, ']');

    if (system_prompt) |sys| {
        try buf.appendSlice(allocator, ",\"system_instruction\":{\"parts\":[{\"text\":");
        try root.appendJsonString(&buf, allocator, sys);
        try buf.appendSlice(allocator, "}]}");
    }

    try buf.appendSlice(allocator, ",\"generationConfig\":{\"temperature\":");
    var temp_buf: [16]u8 = undefined;
    const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{temperature}) catch return error.VertexApiError;
    try buf.appendSlice(allocator, temp_str);
    try buf.appendSlice(allocator, ",\"maxOutputTokens\":");

    const max_output_tokens = request.max_tokens orelse VertexProvider.DEFAULT_MAX_OUTPUT_TOKENS;
    var max_buf: [16]u8 = undefined;
    const max_str = std.fmt.bufPrint(&max_buf, "{d}", .{max_output_tokens}) catch return error.VertexApiError;
    try buf.appendSlice(allocator, max_str);
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "buildGenerateUrl normalizes model forms" {
    const alloc = std.testing.allocator;
    const base = "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models/";

    const url1 = try buildGenerateUrl(alloc, base, "gemini-2.5-pro");
    defer alloc.free(url1);
    try std.testing.expectEqualStrings(
        "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models/gemini-2.5-pro:generateContent",
        url1,
    );

    const url2 = try buildGenerateUrl(alloc, base, "models/gemini-2.5-flash");
    defer alloc.free(url2);
    try std.testing.expect(std.mem.indexOf(u8, url2, "models/gemini-2.5-flash:generateContent") != null);

    const url3 = try buildGenerateUrl(alloc, base, "publishers/google/models/gemini-2.0-flash");
    defer alloc.free(url3);
    try std.testing.expect(std.mem.indexOf(u8, url3, "models/gemini-2.0-flash:generateContent") != null);
}

test "buildStreamUrl appends alt=sse" {
    const alloc = std.testing.allocator;
    const base = "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models";
    const url = try buildStreamUrl(alloc, base, "gemini-2.5-pro");
    defer alloc.free(url);
    try std.testing.expect(std.mem.endsWith(u8, url, ":streamGenerateContent?alt=sse"));
}

test "buildDefaultBase global endpoint" {
    const alloc = std.testing.allocator;
    const base = try VertexProvider.buildDefaultBase(alloc, "proj-1", "global");
    defer alloc.free(base);
    try std.testing.expectEqualStrings(
        "https://aiplatform.googleapis.com/v1/projects/proj-1/locations/global/publishers/google/models",
        base,
    );
}

test "buildDefaultBase regional endpoint" {
    const alloc = std.testing.allocator;
    const base = try VertexProvider.buildDefaultBase(alloc, "proj-2", "us-central1");
    defer alloc.free(base);
    try std.testing.expectEqualStrings(
        "https://us-central1-aiplatform.googleapis.com/v1/projects/proj-2/locations/us-central1/publishers/google/models",
        base,
    );
}

test "provider creates with explicit token and base_url" {
    const p = VertexProvider.init(std.testing.allocator, "ya29.token", "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models");
    try std.testing.expect(p.auth != null);
    try std.testing.expect(p.base != null);
    try std.testing.expectEqualStrings("config", p.authSource());
    try std.testing.expectEqualStrings("base_url config", p.endpointSource());
}

test "provider rejects whitespace explicit token" {
    const p = VertexProvider.init(std.testing.allocator, "   ", "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models");
    const src = p.authSource();
    try std.testing.expect(!std.mem.eql(u8, src, "config"));
}

test "provider getName returns Vertex" {
    var p = VertexProvider.init(std.testing.allocator, "ya29.token", "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models");
    const prov = p.provider();
    try std.testing.expectEqualStrings("Vertex", prov.getName());
}

test "streaming support is enabled" {
    try std.testing.expect(VertexProvider.vtable.supports_streaming != null);
    try std.testing.expect(VertexProvider.vtable.stream_chat != null);
}

test "streamChatImpl fails without credentials" {
    var p = VertexProvider{
        .auth = null,
        .base = .{ .config = "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models" },
        .allocator = std.testing.allocator,
    };

    const prov = p.provider();
    const msgs = [_]root.ChatMessage{root.ChatMessage.user("test")};
    const req = ChatRequest{ .messages = &msgs, .model = "gemini-2.5-pro" };

    const DummyCallback = struct {
        fn cb(_: *anyopaque, _: root.StreamChunk) void {}
    };
    var ctx: u8 = 0;

    try std.testing.expectError(
        error.CredentialsNotSet,
        prov.streamChat(std.testing.allocator, req, "gemini-2.5-pro", 0.7, &DummyCallback.cb, @ptrCast(&ctx)),
    );
}

test "chatWithSystem fails without endpoint base" {
    var p = VertexProvider{
        .auth = .{ .explicit_token = "ya29.token" },
        .base = null,
        .allocator = std.testing.allocator,
    };

    const prov = p.provider();
    try std.testing.expectError(
        error.VertexBaseUrlNotSet,
        prov.chatWithSystem(std.testing.allocator, null, "hi", "gemini-2.5-pro", 0.7),
    );
}

test "buildChatRequestBody plain text" {
    const alloc = std.testing.allocator;
    const msgs = [_]root.ChatMessage{root.ChatMessage.user("hello")};
    const body = try buildChatRequestBody(alloc, .{ .messages = &msgs }, 0.7);
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const contents = parsed.value.object.get("contents").?.array;
    try std.testing.expectEqual(@as(usize, 1), contents.items.len);
    try std.testing.expectEqualStrings("user", contents.items[0].object.get("role").?.string);
}

test "buildChatRequestBody honors max_tokens" {
    const alloc = std.testing.allocator;
    const msgs = [_]root.ChatMessage{root.ChatMessage.user("hello")};
    const body = try buildChatRequestBody(alloc, .{ .messages = &msgs, .max_tokens = 1234 }, 0.2);
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const gen = parsed.value.object.get("generationConfig").?.object;
    try std.testing.expectEqual(@as(i64, 1234), gen.get("maxOutputTokens").?.integer);
}

test "buildChatRequestBody with image base64" {
    const alloc = std.testing.allocator;
    const parts = [_]root.ContentPart{root.makeBase64ImagePart("QUJD", "image/png")};
    const msg = root.ChatMessage{
        .role = .user,
        .content = "",
        .content_parts = &parts,
    };
    const msgs = [_]root.ChatMessage{msg};

    const body = try buildChatRequestBody(alloc, .{ .messages = &msgs }, 0.7);
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();

    const inline_data = parsed.value.object.get("contents").?.array.items[0]
        .object.get("parts").?.array.items[0]
        .object.get("inlineData").?.object;
    try std.testing.expectEqualStrings("image/png", inline_data.get("mimeType").?.string);
    try std.testing.expectEqualStrings("QUJD", inline_data.get("data").?.string);
}

test "parse Gemini-style response via shared parser" {
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}
    ;
    const text = try gemini.GeminiProvider.parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ok", text);
}

test "deinit frees owned env allocations" {
    const alloc = std.testing.allocator;
    var p = VertexProvider{
        .auth = .{ .env_vertex_oauth_token = try alloc.dupe(u8, "ya29.token") },
        .base = .{ .env = try alloc.dupe(u8, "https://aiplatform.googleapis.com/v1/projects/p/locations/global/publishers/google/models") },
        .allocator = alloc,
    };

    VertexProvider.deinitImpl(@ptrCast(&p));
    try std.testing.expect(p.auth == null);
    try std.testing.expect(p.base == null);
}
