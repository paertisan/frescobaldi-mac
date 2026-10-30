import Foundation

/// Content of a tool result.
public enum MCPContent: Equatable, Sendable {
    case text(String)
    case image(Data, mimeType: String)

    var json: JSONValue {
        switch self {
        case let .text(text): ["type": "text", "text": .string(text)]
        case let .image(data, mimeType):
            ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
        }
    }
}

public struct MCPToolResult: Equatable, Sendable {
    public var content: [MCPContent]
    public var isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    /// A result whose text is `value` as pretty-printed JSON.
    public static func json(_ value: JSONValue) -> MCPToolResult {
        MCPToolResult(content: [.text(value.encodedString(pretty: true))])
    }
}

/// An error a tool reports to the model (a tool result with isError), as
/// opposed to a protocol error.
public struct MCPToolError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Hints for clients about what a tool does (MCP tool annotations).
public struct MCPToolAnnotations: Sendable {
    public var readOnly: Bool
    public var destructive: Bool
    public var idempotent: Bool

    public init(readOnly: Bool, destructive: Bool = false, idempotent: Bool = false) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.idempotent = idempotent
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["readOnlyHint": .bool(readOnly), "openWorldHint": false]
        if !readOnly {
            object["destructiveHint"] = .bool(destructive)
            object["idempotentHint"] = .bool(idempotent)
        }
        return .object(object)
    }
}

public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var annotations: MCPToolAnnotations
    public var run: @Sendable (JSONValue) async throws -> MCPToolResult

    public init(name: String, title: String, description: String, inputSchema: JSONValue,
                annotations: MCPToolAnnotations, run: @escaping @Sendable (JSONValue) async throws -> MCPToolResult) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.run = run
    }

    var listing: JSONValue {
        ["name": .string(name), "title": .string(title), "description": .string(description),
         "inputSchema": inputSchema, "annotations": annotations.json]
    }
}

/// A Model Context Protocol server with tools only, speaking JSON-RPC 2.0
/// as newline-delimited JSON on stdin/stdout (the stdio transport).
public final class MCPServer: @unchecked Sendable {
    /// Protocol versions this server can speak; all have the tool features used here.
    public static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    public let name: String
    public let version: String
    public let instructions: String?
    public let tools: [MCPTool]
    private let toolsByName: [String: MCPTool]
    private let outputLock = NSLock()

    public init(name: String, version: String, instructions: String? = nil, tools: [MCPTool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Handles one incoming message and returns the response line, or nil
    /// for notifications.
    public func handle(_ line: String) async -> String? {
        let message: JSONValue
        do {
            message = try JSONValue.parse(line)
        } catch {
            return Self.errorResponse(id: .null, code: -32700, message: "Parse error").encodedString()
        }
        guard case .object = message, let method = message["method"]?.string else {
            return Self.errorResponse(id: message["id"] ?? .null, code: -32600, message: "Invalid request")
                .encodedString()
        }
        guard let id = message["id"], !id.isNull else { return nil } // a notification
        let params = message["params"] ?? .object([:])
        let response: JSONValue
        switch method {
        case "initialize":
            response = Self.resultResponse(id: id, initializeResult(params))
        case "ping":
            response = Self.resultResponse(id: id, .object([:]))
        case "tools/list":
            response = Self.resultResponse(id: id, ["tools": .array(tools.map(\.listing))])
        case "tools/call":
            response = await callTool(id: id, params: params)
        default:
            response = Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
        return response.encodedString()
    }

    private func initializeResult(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.string ?? ""
        let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions.last!
        var result: [String: JSONValue] = [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": .string(name), "version": .string(self.version)],
        ]
        if let instructions { result["instructions"] = .string(instructions) }
        return .object(result)
    }

    private func callTool(id: JSONValue, params: JSONValue) async -> JSONValue {
        guard let name = params["name"]?.string, let tool = toolsByName[name] else {
            return Self.errorResponse(id: id, code: -32602,
                                      message: "Unknown tool: \(params["name"]?.string ?? "(none)")")
        }
        let arguments = params["arguments"] ?? .object([:])
        let result: MCPToolResult
        do {
            result = try await tool.run(arguments)
        } catch {
            result = MCPToolResult(content: [.text(error.localizedDescription)], isError: true)
        }
        var object: [String: JSONValue] = ["content": .array(result.content.map(\.json))]
        if result.isError { object["isError"] = true }
        return Self.resultResponse(id: id, .object(object))
    }

    static func resultResponse(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    // MARK: stdio

    /// Serves requests from stdin until it closes. Requests run concurrently
    /// (an engrave can take a while); each response is one line on stdout.
    public func run(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) async {
        await withTaskGroup(of: Void.self) { group in
            do {
                for try await line in input.bytes.lines where !line.isEmpty {
                    group.addTask {
                        guard let response = await self.handle(line) else { return }
                        self.write(response, to: output)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("frescobaldi-mcp: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    private func write(_ line: String, to output: FileHandle) {
        outputLock.withLock { output.write(Data((line + "\n").utf8)) }
    }
}
