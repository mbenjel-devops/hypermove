# Place *.ps1 hook scripts here. They run in alphabetical order.
# Hook point: pre-pipeline (runs once before any VM is processed).
# Contract: receives context JSON via -ContextPath / $env:MIG_HOOK_CONTEXT_PATH.
# pre-* hooks are BLOCKING: a non-zero exit stops the run.
