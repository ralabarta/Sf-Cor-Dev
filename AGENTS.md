# Project Agent Rules

- Write technical artifacts in English.
- Never commit secrets or local Engram memory chunks; only `.engram/config.json` is repository configuration.
- Keep changes minimal, scoped, and reproducible.
- Run fresh applicable checks and GGA before delivery.
- Do not change receipt-driven development (RDD) mode without explicit authorization.
- Invoke GGA with `env gga` to bypass shell aliases without relying on an absolute binary path.
- When `.codegraph/` exists, use Codegraph before textual searches to understand or locate code; never version the local index, only `.codegraph/.gitignore`.
