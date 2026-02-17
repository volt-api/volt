// Volt Core Library
// The engine that powers the Volt API client.

pub const VoltFile = @import("volt_file.zig");
pub const HttpClient = @import("http_client.zig");
pub const Environment = @import("environment.zig");
pub const Importer = @import("importer.zig");

// M2 modules
pub const GraphQL = @import("graphql.zig");
pub const MockServer = @import("mock_server.zig");
pub const Bench = @import("bench.zig");
pub const Exporter = @import("exporter.zig");
pub const Scripting = @import("scripting.zig");
pub const CollectionRunner = @import("collection_runner.zig");
pub const History = @import("history.zig");

// M3 modules
pub const TestGenerator = @import("test_generator.zig");
pub const Formatter = @import("formatter.zig");
pub const Config = @import("config.zig");

// M4+ modules
pub const Workflow = @import("workflow.zig");
pub const Validator = @import("validator.zig");
pub const Multipart = @import("multipart.zig");
pub const Signing = @import("signing.zig");
pub const Completions = @import("completions.zig");
pub const Snippet = @import("snippet.zig");
pub const Har = @import("har.zig");
pub const DocGenerator = @import("doc_generator.zig");
pub const Retry = @import("retry.zig");
pub const RateLimiter = @import("rate_limiter.zig");
pub const Cache = @import("cache.zig");
pub const Monitor = @import("monitor.zig");
pub const OAuth = @import("oauth.zig");
pub const DiffEngine = @import("diff_engine.zig");
pub const WebSocket = @import("ws.zig");
pub const SSE = @import("sse.zig");

// Tier 1+2 modules
pub const CurlImport = @import("curl_import.zig");
pub const OpenAPIImport = @import("openapi_import.zig");
pub const DynamicVars = @import("dynamic_vars.zig");
pub const DataDriver = @import("data_driver.zig");
pub const JUnit = @import("junit.zig");
pub const CookieJar = @import("cookie_jar.zig");
pub const Grpc = @import("grpc.zig");
pub const JsonPath = @import("jsonpath.zig");
pub const TestReport = @import("test_report.zig");
pub const InsomniaImport = @import("insomnia_import.zig");

// Competitive feature modules
pub const Secrets = @import("secrets.zig");
pub const Watch = @import("watch.zig");
pub const CI = @import("ci.zig");
pub const Share = @import("share.zig");
pub const Mqtt = @import("mqtt.zig");
pub const SocketIO = @import("socketio.zig");
pub const Proxy = @import("proxy.zig");
pub const Themes = @import("themes.zig");
pub const Plugin = @import("plugin.zig");
pub const OpenAPIDesigner = @import("openapi_designer.zig");
pub const Replay = @import("replay.zig");

// Collection & protocol modules
pub const CollectionOrganizer = @import("collection_organizer.zig");
pub const H2 = @import("h2.zig");
pub const OAuthFlow = @import("oauth_flow.zig");
pub const ResponseViewer = @import("response_viewer.zig");

// Web UI modules
pub const WebServer = @import("web_server.zig");
pub const WebApi = @import("web_api.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
