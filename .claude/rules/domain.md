---
paths:
  - "src/contexts/*/domain/**"
---
Domain code is pure. Model workflows as explicit state machines: states and transitions are data,
guards are pure functions. Return `Result` for expected failures. If you need time, randomness,
files or processes, add a port in `application/` and receive the value as a parameter.
