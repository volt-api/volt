# AWS STS Plugin

A VOLT plugin that obtains temporary AWS credentials by assuming an IAM role
via `aws sts assume-role`.

## Prerequisites

- AWS CLI installed and on your PATH
- Valid base credentials configured (environment variables, `~/.aws/credentials`,
  or an instance profile) with `sts:AssumeRole` permission

## Configuration

| Variable           | Required | Default          | Description                      |
|--------------------|----------|------------------|----------------------------------|
| `AWS_ROLE_ARN`     | Yes      | —                | ARN of the IAM role to assume    |
| `AWS_SESSION`      | No       | `volt-session`   | Session name for CloudTrail logs |
| `AWS_STS_DURATION` | No       | `3600`           | Credential lifetime in seconds   |

You can also pass the role ARN as the first positional argument.

## Provided Variables

After a successful run the plugin exports:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN`
- `AWS_STS_EXPIRATION`

These are available in your `.volt` request files as `{{AWS_ACCESS_KEY_ID}}`, etc.

## Example

```
volt run my-request.volt --plugin aws-sts --set AWS_ROLE_ARN=arn:aws:iam::123456789012:role/MyRole
```
