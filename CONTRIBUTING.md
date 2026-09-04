# Contributing to Airlock

## Report bugs and suggest features

Open an [issue](https://github.com/jss367/Airlock/issues/new/choose). Search [existing issues](https://github.com/jss367/Airlock/issues) first, and add relevant details to an existing report when possible.

For bugs, include:

- What you expected and what actually happened.
- Steps to reproduce, ideally with a minimal configuration.
- Your Airlock version (`airlock --version`) or source commit, and macOS version.
- Relevant configuration, screenshots, or a short recording.
- `airlock debug-windows` output when the problem concerns a particular window.

Check diagnostic output and configuration for private information before posting them.

For feature requests, describe the workflow you want to support, how you handle it now, and the behavior you would like Airlock to provide.

## Submit pull requests

Small fixes and documentation improvements can go straight to a pull request. For larger changes, start with an issue describing the problem, proposed behavior, and any configuration or command changes so the design can be discussed before implementation.

- Keep changes focused and explain the problem and resulting behavior in the pull request description.
- Link related issues. Use `Fixes #<number>` when the change resolves an issue.
- Include validation results. Run `./build.sh` for code changes; check links and render documentation for documentation changes. The fuller continuous integration checks are described in the [development instructions](dev-docs/development.md).
- Update documentation and examples when behavior changes.
- Open pull requests ready for review unless you want early feedback on unfinished work.

See the [development instructions](dev-docs/development.md) for building and testing, and the [architecture notes](dev-docs/architecture.md) for a codebase overview.

By contributing, you agree to license your contributions under the repository's [MIT License](LICENSE.txt).
