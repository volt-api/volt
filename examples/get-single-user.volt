name: Get Single User
method: GET
url: https://jsonplaceholder.typicode.com/users/1
headers:
  - Accept: application/json
tests:
  - status equals 200
  - body contains Leanne
