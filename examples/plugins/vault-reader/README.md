# Vault Reader Plugin

A VOLT plugin that reads secrets from HashiCorp Vault and exposes them as
request variables.

## Prerequisites

- `curl` installed and on your PATH
- A running Vault instance
- A valid Vault token with read access to the target path

## Configuration

| Variable            | Required | Default | Description                              |
|---------------------|----------|---------|------------------------------------------|
| `VAULT_ADDR`        | Yes      | —       | Base URL of the Vault server             |
| `VAULT_TOKEN`       | Yes      | —       | Vault authentication token               |
| `VAULT_PATH`        | Yes      | —       | Secret path (e.g. `secret/data/myapp`)   |
| `VAULT_API_VERSION` | No       | `v2`    | KV secrets engine version (`v1` or `v2`) |

You can also pass the secret path as the first positional argument.

## Provided Variables

All key-value pairs stored at the given Vault path are exported as VOLT
variables. For example, if the secret contains `{"db_host": "10.0.0.1",
"db_pass": "s3cret"}`, you can reference `{{db_host}}` and `{{db_pass}}`
in your `.volt` files.

## Example

```
volt run my-request.volt --plugin vault-reader \
    --set VAULT_ADDR=https://vault.example.com \
    --set VAULT_TOKEN=hvs.xxxx \
    --set VAULT_PATH=secret/data/myapp
```
