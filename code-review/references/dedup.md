<!-- Moved from SKILL.md `## Dedup` (c03df8c:128-133), byte-identical; source per that commit's build notes: phase-2-recall:11 + part-3:28-30. It lives here so workflow step agents can read the rule without SKILL.md's orchestration text. -->
## Dedup

Pool all candidates. Dedup near-duplicates only: same defect, same location,
same reason → keep one, the one with the most concrete failure scenario. Do
NOT let one angle's conclusions suppress another's — if two angles flag the
same line for different reasons, record both.
