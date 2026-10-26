# guard-timekeeping
Digital timekeeping app for security guard workforce (Constellis)

## MCP servers (preconfigured)

This repo ships with MCP server configs, so GitHub Copilot picks them up automatically when you open or clone it. No manual setup is needed.

| Server | What it gives Copilot | Type |
|---|---|---|
| `azure` | Azure MCP: manage and query Azure resources, best practices, Bicep and Terraform guidance | local (`npx @azure/mcp`) |
| `microsoft-learn` | Latest Microsoft/Azure docs and code samples | remote HTTP |
| `github` | GitHub repos, issues, PRs, Actions (VS Code only; built into Copilot CLI) | remote HTTP |
| `playwright` | Browser automation for UI testing | local (`npx @playwright/mcp`) |

Config files:
- **VS Code (Copilot Chat / Agent mode):** [.vscode/mcp.json](.vscode/mcp.json). Open the repo, then click **Start** on each server in the file, or run `MCP: List Servers`.
- **Copilot CLI:** [.github/mcp.json](.github/mcp.json). Run `copilot` from the repo folder and check it with `/mcp`.

### Prerequisites
- [Node.js](https://nodejs.org/) LTS (for `npx`)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), signed in with `az login` (the Azure MCP uses your Azure CLI credentials)
- GitHub sign-in in VS Code / Copilot CLI
