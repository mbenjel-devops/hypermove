# Place *.ps1 hook scripts here. They run in alphabetical order.
# Hook point: on-failure (runs when a VM pipeline fails or is rolled back).
# Contract: receives context JSON via -ContextPath / $env:MIG_HOOK_CONTEXT_PATH.
# on-failure hooks are NON-BLOCKING: a non-zero exit is logged as a warning only.
# Typical use: open an incident ticket, page on-call, attach logs.
