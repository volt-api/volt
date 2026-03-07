name: Who Am I
method: GET
url: http://127.0.0.1:8787/me
auth:
  type: bearer
  token: {{token}}
tests:
  - status equals 200
  - $.received_auth equals Bearer abc123

