name: GraphQL Countries Query
method: POST
url: https://countries.trevorblades.com/graphql
headers:
  - Content-Type: application/json
  - Accept: application/json
body:
  type: json
  content: |
    {"query": "{ countries(filter: { continent: { eq: \"EU\" } }) { name capital currency } }"}
tests:
  - status equals 200
  - body contains countries
