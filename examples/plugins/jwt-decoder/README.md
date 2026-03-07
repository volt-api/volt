# JWT Decoder Plugin

A VOLT plugin that finds and decodes JSON Web Tokens in API responses,
displaying the header, payload, and expiration status.

## Prerequisites

- `base64` command available (included in most Unix-like systems)
- `grep` with `-oE` support

## How It Works

This plugin runs as a `post_response` hook. After each request completes,
VOLT pipes the response body to the plugin. The script:

1. Searches the body for JWT patterns (`xxxxx.yyyyy.zzzzz`)
2. Base64url-decodes the header and payload segments
3. Checks the `exp` claim against the current time
4. Prints a summary showing decoded contents and validity

## Configuration

No configuration is required. The plugin reads the response body from
stdin automatically.

## Example Output

```
--- JWT #1 ---
Header:  {"alg":"RS256","typ":"JWT"}
Payload: {"sub":"1234567890","name":"Jane Doe","iat":1700000000,"exp":1700003600}
Status:  VALID (expires in 2400s)
```

## Usage

```
volt run my-request.volt --plugin jwt-decoder
```
