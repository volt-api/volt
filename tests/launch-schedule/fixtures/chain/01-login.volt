name: Login
method: GET
url: http://127.0.0.1:8787/login
post_script: |
  extract token body.token
tests:
  - status equals 200
  - $.token equals abc123

