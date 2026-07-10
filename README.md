# bootstrap

Rapid bootstrapping of **KH apps** — small, self-contained scripts that
provision a fresh host and install a KH tool in one line. Public and LGPL-3.0
so they can be piped straight onto a new box:

```bash
curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/bootstrap/main/<script>.sh | sudo bash
```

Published by [KH Projects & Solutions](https://github.com/KH-Project-Solutions).
The scripts are public; the app binaries they pull are private (fetched with a
KH-ServiceBot PAT).

## Scripts

### `kh-svm.sh`

Provisions a Debian 13 host and installs **kh-svm** (the Odoo production
manager): Docker engine, the `khsvm` service user, the binary from kh-svm's
latest private Release, and the `khsvmd` daemon. Prompts for a KH-ServiceBot PAT
(never written to disk); pre-set `KH_SVM_PAT` for unattended runs.

```bash
curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/bootstrap/main/kh-svm.sh | sudo bash
```

Kept in sync automatically from the private
[`kh-svm`](https://github.com/KH-Project-Solutions/kh-svm) repo — edit it there,
not here.

### `prepare_deploymonkey.sh`

Provisions a fresh deploy host and locks it back down when you're finished.
Must be run as root (`sudo`).

**Default run** — update the system and open temporary root SSH access:

- `apt update && apt upgrade -y`
- generates a random 32-char root password (printed to the terminal)
- enables root login over SSH

```bash
curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/bootstrap/main/prepare_deploymonkey.sh | sudo bash
```

**Finalize** — undo the access once the box is set up:

- blanks the root password
- forbids root SSH login

```bash
curl -fsSL https://raw.githubusercontent.com/KH-Project-Solutions/bootstrap/main/prepare_deploymonkey.sh | sudo bash -s -- --finalize
```

## License

LGPL-3.0 — see [LICENSE](LICENSE).
