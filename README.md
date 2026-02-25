# MTP-manager

## Beta script (v3.5)

Use the **raw** GitHub URL for download. `.../blob/...` returns HTML and Bash will fail with `<!DOCTYPE html>`.

```bash
curl -fsSL https://raw.githubusercontent.com/tarpy-socdev/MTP-manager/main/beta/v3.5_go.sh -o v3.5_go.sh
bash -n v3.5_go.sh
sudo bash v3.5_go.sh
```

### Quick check after download

```bash
head -n 1 v3.5_go.sh
```

Expected first line:

```text
#!/bin/bash
```
