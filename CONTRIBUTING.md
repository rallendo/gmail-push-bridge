# Contributing to Gmail Push Bridge

Thank you for considering contributing to Gmail Push Bridge!

## How to Contribute

### Reporting Bugs & Requesting Features
- Please use the provided [Issue Templates](https://github.com/rallendo/gmail-push-bridge/issues/new/choose).
- For questions or general discussion, head over to [Discussions](https://github.com/rallendo/gmail-push-bridge/discussions).

### Submitting Pull Requests
1. Fork the repository and create your branch from `main`.
2. Ensure your changes compile cleanly on macOS:
   ```zsh
   swift build
   ```
   Or package the app bundle:
   ```zsh
   ./scripts/build-app.sh
   ```
3. Test your changes locally on macOS with Mail.app.
4. Open a pull request against `main`. Fill in the PR checklist completely.
5. All pull requests must pass automated CI checks and receive review from `@rallendo` before merging.

### Security
If you identify a security issue, do **not** file a public issue. See [SECURITY.md](SECURITY.md) for instructions on confidential disclosure.
