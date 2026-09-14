# Contributing to LovePilot

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Getting Started

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/lovepilot.git
   cd lovepilot
   ```
3. Install dependencies:
   ```bash
   npm install
   ```
4. Create a branch for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Development Workflow

### Running in Development Mode

1. Start TypeScript watch mode:
   ```bash
   npm run dev
   ```

2. In another terminal, start the test game:
   ```bash
   love game/
   ```

3. Test with MCP Inspector:
   ```bash
   npx @modelcontextprotocol/inspector node build/index.js
   ```

### Making Changes

#### TypeScript/MCP Server Changes

- Server code is in `src/index.ts`
- Follow TypeScript best practices
- Ensure proper error handling for TCP connections
- Test with the example game after changes

#### Lua Bridge Changes

- Bridge code is in `game/mcp_bridge.lua`
- Keep the API simple and well-documented
- Ensure non-blocking socket operations
- Test JSON encoding/decoding thoroughly

#### Example Game Changes

- Game code is in `game/main.lua`
- Keep it simple and illustrative
- Demonstrate MCP capabilities clearly

## Code Style

### TypeScript

- Use TypeScript strict mode
- Prefer `async/await` over callbacks
- Add JSDoc comments for public APIs
- Follow existing formatting

### Lua

- Use 4 spaces for indentation
- Use `snake_case` for functions and variables
- Add comments for complex logic
- Keep functions focused and small

## Testing

This project does not have an automated test suite yet. Verification is done
manually against a running game, using the [MCP Inspector](https://github.com/modelcontextprotocol/inspector):

```bash
love game/           # terminal 1: start the example game (bridge on port 12345)
npx @modelcontextprotocol/inspector node build/index.js   # terminal 2: connect the inspector
```

### Manual Testing Checklist

Before submitting a PR, verify:

- [ ] Game starts without errors
- [ ] MCP server connects to game successfully
- [ ] `get_objects` returns correct data (all objects, and a single one by id)
- [ ] `run_lua` executes code correctly
- [ ] Error handling works (try invalid commands)
- [ ] Game and server shut down cleanly

### Testing New Features

- Add example usage in PR description
- Update documentation if needed
- Test edge cases and error conditions

## Submitting Changes

1. Commit your changes with clear messages:
   ```bash
   git commit -m "Add feature: brief description"
   ```

2. Push to your fork:
   ```bash
   git push origin feature/your-feature-name
   ```

3. Open a Pull Request on GitHub with:
   - Clear description of changes
   - Motivation for the changes
   - Testing performed
   - Any breaking changes

## Pull Request Guidelines

### Good PR Practices

- Keep PRs focused on a single feature or fix
- Write clear commit messages
- Update documentation for user-facing changes
- Respond to review feedback promptly
- Ensure your branch is up to date with main

### PR Title Format

Use conventional commits style:
- `feat: Add new MCP tool for X`
- `fix: Resolve connection issue when Y`
- `docs: Update README with Z`
- `refactor: Improve error handling in W`

## Areas for Contribution

### High Priority

- **Additional MCP tools**: New ways to interact with games
- **Better error messages**: Improve debugging experience
- **Performance optimization**: Reduce latency and overhead
- **Documentation**: Examples, tutorials, API docs

### Feature Ideas

- Support for multiple game instances
- WebSocket transport option
- Game state snapshots/restore
- Real-time change watching
- Visualization tools
- Testing framework integration

### Known Issues

Check the [Issues](https://github.com/InfiniteLoopRD/lovepilot/issues) page for:
- Bug reports
- Feature requests
- Good first issues (labeled `good-first-issue`)

## Code of Conduct

### Our Standards

- Be respectful and inclusive
- Welcome newcomers
- Focus on constructive feedback
- Help others learn

### Unacceptable Behavior

- Harassment or discrimination
- Trolling or inflammatory comments
- Publishing others' private information
- Other unprofessional conduct

## Questions?

- Open a [Discussion](https://github.com/InfiniteLoopRD/lovepilot/discussions)
- Check existing [Issues](https://github.com/InfiniteLoopRD/lovepilot/issues)
- Review the [README](README.md) and documentation

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
