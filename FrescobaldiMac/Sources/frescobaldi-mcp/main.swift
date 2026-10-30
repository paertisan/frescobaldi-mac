import Foundation
import FrescobaldiMCP

// MCP server for Frescobaldi, over stdio. Claude Code:
//   claude mcp add frescobaldi -- /Applications/Frescobaldi.app/Contents/Helpers/frescobaldi-mcp
// stdout carries only protocol messages; diagnostics go to stderr.

signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    FileHandle.standardError.write(Data("frescobaldi-mcp \(FrescobaldiTools.version)\n".utf8))
    exit(0)
}
let server = MCPServer(name: FrescobaldiTools.serverName, version: FrescobaldiTools.version,
                       instructions: FrescobaldiTools.instructions, tools: FrescobaldiTools.all())
await server.run()
