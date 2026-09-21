# Conclave AX end-to-end fixture

This deliberately small repository contains one bug for the Forge integration test:

```js
add(2, 3) // incorrectly returns -1
```

The Conclave goal is to fix `add`, add regression coverage, and verify the implementation with the repository's real `pnpm test` command.
