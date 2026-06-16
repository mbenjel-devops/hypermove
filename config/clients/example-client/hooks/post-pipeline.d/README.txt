# Place *.ps1 hook scripts here. They run in alphabetical order.
# Hook point: post-pipeline (runs once after all VMs are processed).
# Contract: receives context JSON via -ContextPath / $env:MIG_HOOK_CONTEXT_PATH.
# post-* hooks are NON-BLOCKING: a non-zero exit is logged as a warning only.
