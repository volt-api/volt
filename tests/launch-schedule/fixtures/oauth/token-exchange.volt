name: OAuth Token Exchange
method: POST
url: http://127.0.0.1:9090/oauth/token
headers:
  - Content-Type: application/x-www-form-urlencoded
  - Accept: application/json
auth:
  type: oauth_cc
  client_id: volt-test-app
  client_secret: test-secret-key-12345
  token_url: http://127.0.0.1:9090/oauth/token
  scope: read write
body:
  type: form
  content: grant_type=client_credentials
tests:
  - status equals 200
  - $.access_token exists
