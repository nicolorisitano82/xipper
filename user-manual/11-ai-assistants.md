# 11. AI assistants (MCP)

Xipper includes a Model Context Protocol (MCP) server. With it, an AI assistant can work with archives on your Mac: Claude Desktop, Claude Code, or any other MCP client. You decide which folders it may touch.

## What an assistant can do

| Tool | Does |
|---|---|
| `archive_list`, `archive_info` | List an archive, describe it |
| `archive_read_entry` | Read one file inside an archive, without extracting it |
| `archive_test` | Verify an archive |
| `archive_create`, `archive_extract`, `archive_convert` | Create, extract, change format |
| `checksum_manifest` | Checksum lists |
| `bgzf_compress`, `bgzf_convert`, `bgzf_check`, `cram_convert`, `genomics_index`, `genomics_check` | Genomics ([chapter 9](09-genomics.md)) |

## Safety

- **Only the allowed folders.** Assistants can touch only the folders you list. Every path is checked, links included, and anything else is refused.
- **Read-only mode** allows listing and verifying, but nothing that writes.
- **Passwords never go through the chat.** Store a password in the Keychain under a name; the assistant refers to it by that name (`password_ref`) and never sees it. Passing passwords as arguments is refused unless you allow it explicitly (`--allow-password-argument`).
- **Every operation is logged** to `~/Library/Logs/Xipper/mcp-audit.jsonl`, without passwords or file contents. `--no-audit` turns the log off.

## Setting it up

In the app: **Settings › Integrations › AI Assistants (MCP)**.
- **Add Allowed Folder…** adds a folder; **Remove** takes one away.
- **Read-only (list and verify only)** limits what assistants can do.

From Terminal:

```bash
xipper mcp install          # prints the exact lines for Claude Code and Claude Desktop
```

Claude Code, for all projects:

```bash
claude mcp add --transport stdio --scope user xipper -- /usr/local/bin/xipper mcp --allow ~/Documents
```

Claude Desktop: add Xipper to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
"mcpServers": { "xipper": { "command": "/usr/local/bin/xipper", "args": ["mcp", "--allow", "/Users/you/Documents"] } }
```

Or build a bundle you can install by double-clicking:

```bash
xipper mcp bundle -o Xipper.mcpb
```

Passwords for assistants:

```bash
xipper mcp password set reports     # asks for it; the assistant uses password_ref: "reports"
xipper mcp password list
xipper mcp password delete reports
```

Options of `xipper mcp`:

| Option | Meaning |
|---|---|
| `--allow DIR` | An allowed folder; repeatable. Folders after `--` are allowed too |
| `--read-only` | List and verify only |
| `--config FILE` | Another settings file. The default is `~/Library/Application Support/Xipper/mcp.json`, shared with the app |
| `--allow-password-argument` | Let the assistant pass passwords directly (not recommended) |
| `--no-audit` | No log |
