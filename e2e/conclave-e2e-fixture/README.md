# Conclave AX end-to-end fixture

This deliberately small repository contains a sample defect for execution-path
acceptance tests:

```js
add(2, 3) // incorrectly returns -1
```

The acceptance scenario fixes `add`, adds regression coverage, and verifies the
implementation with the repository test command.
