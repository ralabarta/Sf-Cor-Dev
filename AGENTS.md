# Project Agent Rules

- Write technical artifacts in English.
- Never commit secrets or local Engram memory chunks; only `.engram/config.json` is repository configuration.
- Keep changes minimal, scoped, and reproducible.
- Run fresh applicable checks and GGA before delivery.
- Run GGA in the maintainer or pre-commit context; CI and release workflows must not depend on an AI provider or secret unless one is explicitly configured.
- Do not change receipt-driven development (RDD) mode without explicit authorization.
- Invoke GGA with `env gga` to bypass shell aliases without relying on an absolute binary path.
- When `.codegraph/` exists, use Codegraph before textual searches to understand or locate code; never version the local index, only `.codegraph/.gitignore`.
