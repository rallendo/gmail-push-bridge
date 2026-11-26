# Contributing to Gmail Push Bridge

Thank you for considering contributing to Gmail Push Bridge!

## How to Contribute

### Reporting Bugs & Requesting Features
- Please use the provided [Issue Templates](https://github.com/rallendo/gmail-push-bridge/issues/new/choose).
- For questions or general discussion, head over to [Discussions](https://github.com/rallendo/gmail-push-bridge/discussions).

### Submitting Pull Requests
1. Fork the repository and create your branch from `main`.
2. Run the unit tests and verify the release build compiles cleanly on macOS:
   ```zsh
   ./scripts/run-tests.sh
   ```
   *(Or run `swift test` directly.)*
   To package the `.app` bundle:
   ```zsh
   ./scripts/build-app.sh
   ```
3. Test your changes locally on macOS with Mail.app.
4. Open a pull request against `main`. Fill in the PR checklist completely.
5. All pull requests must pass `./scripts/run-tests.sh` locally and receive review from `@rallendo` before merging.

### Security
If you identify a security issue, do **not** file a public issue. See [SECURITY.md](SECURITY.md) for instructions on confidential disclosure.
