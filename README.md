# public-tools

Small, self-contained operational tools published by
[KH Projects & Solutions](https://github.com/KH-Project-Solutions). Public and
LGPL-3.0 so they can be piped straight onto a fresh box.

## Tools

### `prepare_deploymonkey.sh`

Provisions a fresh deploy host and locks it back down when you're finished.
Must be run as root (`sudo`).

**Default run** — update the system and open temporary root SSH access:

- `apt update && apt upgrade -y`
- generates a random 32-char root password (printed to the terminal)
- enables root login over SSH

```bash
curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/public-tools/main/prepare_deploymonkey.sh | sudo bash
```

**Finalize** — undo the access once the box is set up:

- blanks the root password
- forbids root SSH login

```bash
curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/public-tools/main/prepare_deploymonkey.sh | sudo bash -s -- --finalize
```

## License

LGPL-3.0 — see [LICENSE](LICENSE).
