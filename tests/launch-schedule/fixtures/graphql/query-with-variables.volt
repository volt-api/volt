name: GraphQL Query With Variables
method: POST
url: http://127.0.0.1:9090/graphql
headers:
  - Content-Type: application/json
  - Accept: application/json
body:
  type: json
  content: |
    {"query": "query GetUser($id: ID!) { user(id: $id) { id name email } }", "variables": {"id": "42"}}
tests:
  - status equals 200
  - $.data.user.id equals 42
