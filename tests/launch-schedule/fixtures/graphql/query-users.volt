name: GraphQL Query Users
method: POST
url: http://127.0.0.1:9090/graphql
headers:
  - Content-Type: application/json
  - Accept: application/json
body:
  type: json
  content: |
    {"query": "{ users { id name email } }"}
tests:
  - status equals 200
