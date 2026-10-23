<!-- Source: system-prompts/skill-code-review-angle-c-cross-file-tracer.md:6-11 (verbatim except that the tool name in the parenthetical is made generic: "search for the symbol"). -->
### Angle C — cross-file tracer

For each function the diff changes, find its callers (search for the symbol) and
check whether the change breaks any call site: a new precondition, a changed
return shape, a new exception, a timing/ordering dependency. Also check callees:
does a parallel change in the same PR make a call unsafe?
