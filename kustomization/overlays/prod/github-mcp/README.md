# github-mcp Overlay

This overlay runs the [GitHub MCP server](https://github.com/github/github-mcp-server) in `http`
mode.  Traefik serves it at `github-mcp.hogs.tswn.us`, and the `mcp-clients` IP allowlist gates it.
The enabled toolsets are `actions`, `context`, `issues`, `pull_requests`, `repos` and `users`.

## Connect A Client

Each caller sends its own token.  The server holds none, and it reads the token from the
`Authorization` header of each request.

```json
{
  "type": "http",
  "url": "https://github-mcp.hogs.tswn.us/",
  "headers": { "Authorization": "Bearer github_token..." }
}
```

Use `https://github-mcp.hogs.tswn.us/readonly` to get the read tools alone.  The header
`X-MCP-Readonly: true` does the same on the default path.

## Scope The Token

Use a fine-grained PAT, and give it the repositories that the caller needs.  Set `Contents`,
`Issues`, `Pull requests` and `Metadata` to `Read-only`.

Set `Actions` to `Read-only` as well.  The caller can then read a workflow, a run, a job and the
logs of a job.  `actions_run_trigger` needs write, so the caller cannot run a workflow, cancel a run
or delete the logs of a run.

## Connect An Agent

Agents reach this server through Bifrost.  The `github` MCP client there uses
`auth_type: per_user_headers`, so each agent sends its own token.  Bifrost keys a token to a Virtual
Key, and keeps it in `mcp_per_user_header_credentials` encrypted with `BIFROST_ENCRYPTION_KEY`.

Set up each Virtual Key by hand, in three steps:

1. Select **Verify** on the `github` client in the Bifrost dashboard, and send one token.  The
   client starts in `pending_verification` until you do this, because it needs a token to read the
   tool list with.  Bifrost keeps this one as an `admin` row that no agent can use.
2. Give the Virtual Key an `mcp_configs` entry for the `github` client.  A Virtual Key without an
   entry sees no tool from this server.
3. Make one call from the Virtual Key.  The call fails, and the error gives a submit URL.  Open that
   URL, and send the token for that key.

To limit which tools a Virtual Key can call, set `virtual_keys[].mcp_configs[].tools_to_execute` in
the dashboard.  Do not add a `governance.virtual_keys` section to `config.json`.  Bifrost then
replaces the Virtual Keys in the database from that file, and the dashboard entries are lost.
